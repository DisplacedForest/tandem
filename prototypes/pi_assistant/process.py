import asyncio
import json
import os
import signal
from pathlib import Path
from typing import Any, Awaitable, Callable


class PiFailure(RuntimeError):
    pass


class PiProcess:
    def __init__(self, node: str, script: Path, timeout: float = 15):
        self.node = node
        self.script = script
        self.timeout = timeout
        self.pids: set[int] = set()
        self.cleanup_blocked = False

    async def run(self, config: dict[str, Any], host: Callable[[dict[str, Any]], Awaitable[Any]],
                  canceled: Callable[[], bool] = lambda: False) -> dict[str, Any]:
        process = await asyncio.create_subprocess_exec(
            self.node, str(self.script), stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.DEVNULL, start_new_session=True, limit=262145,
            cwd=str(self.script.parent), env={'PATH': '/usr/bin:/bin', 'LANG': 'C.UTF-8'},
        )
        self.pids.add(process.pid)
        async def exchange() -> dict[str, Any]:
            assert process.stdin is not None and process.stdout is not None
            process.stdin.write((json.dumps(config) + '\n').encode())
            await process.stdin.drain()
            calls = 0
            while True:
                line = await process.stdout.readline()
                if not line or len(line) > 262144:
                    raise PiFailure('invalid_worker_output')
                event = json.loads(line)
                if not isinstance(event, dict):
                    raise PiFailure('invalid_worker_output')
                if event.get('type') == 'result':
                    if not isinstance(event.get('text'), str) or len(event['text']) > 32000:
                        raise PiFailure('invalid_worker_result')
                    return event
                if event.get('type') not in {'tool', 'model'} or not isinstance(event.get('id'), str):
                    raise PiFailure('invalid_worker_event')
                calls += 1
                if calls > 12 or canceled():
                    raise PiFailure('worker_limit_or_cancel')
                try:
                    result = await host(event)
                    response = {'id': event['id'], 'result': result}
                except (ValueError, OSError, PiFailure):
                    response = {'id': event['id'], 'error': 'host_rejected'}
                process.stdin.write((json.dumps(response) + '\n').encode())
                await process.stdin.drain()
        async def watch_cancel() -> None:
            while not canceled():
                await asyncio.sleep(0.02)
        exchange_task = asyncio.create_task(exchange())
        cancel_task = asyncio.create_task(watch_cancel())
        try:
            done, _ = await asyncio.wait({exchange_task, cancel_task}, timeout=self.timeout, return_when=asyncio.FIRST_COMPLETED)
            if cancel_task in done or canceled():
                raise PiFailure('canceled')
            if exchange_task not in done:
                raise PiFailure('timeout')
            return exchange_task.result()
        except (ValueError, TypeError, KeyError, OSError, asyncio.IncompleteReadError) as exc:
            raise PiFailure('invalid_worker_protocol') from exc
        finally:
            for task in (exchange_task, cancel_task):
                task.cancel()
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            await asyncio.sleep(0.05)
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            await process.wait()
            self.pids.discard(process.pid)
            _, unsettled = await asyncio.wait({exchange_task, cancel_task}, timeout=0.2)
            if unsettled:
                self.cleanup_blocked = True
            try:
                await asyncio.gather(exchange_task, cancel_task, return_exceptions=True)
            finally:
                self.cleanup_blocked = False
