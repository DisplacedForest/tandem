import argparse
import contextlib
import http.client
import http.server
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
from typing import Any, Callable, Iterator


REPOSITORY = Path(__file__).resolve().parents[2]
API = REPOSITORY / 'services' / 'vera-api'
sys.path.insert(0, str(API))
from routers.task_store import StepResult, TaskConflict, TaskStore


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def eventually(check: Callable[[], Any], seconds: float = 12) -> Any:
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        value = check()
        if value:
            return value
        time.sleep(0.025)
    raise AssertionError('The expected isolated engine state did not arrive before its deadline')


@contextlib.contextmanager
def tripwire() -> Iterator[tuple[int, list[str]]]:
    requests: list[str] = []

    class Handler(http.server.BaseHTTPRequestHandler):
        def reject(self) -> None:
            requests.append(self.command)
            self.send_response(503)
            self.send_header('Content-Length', '0')
            self.end_headers()

        do_GET = reject
        do_POST = reject

        def log_message(self, format: str, *args: Any) -> None:
            pass

    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield server.server_port, requests
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=3)
        require(not thread.is_alive(), 'Tripwire thread did not stop')


class Engine:
    def __init__(self, root: Path, executable: Path | None, sentinel: int):
        self.root = root
        self.executable = executable
        self.process: subprocess.Popen[bytes] | None = None
        self.log: Any = None
        self.identity: dict[str, Any] | None = None
        with socket.socket() as reservation:
            reservation.bind(('127.0.0.1', 0))
            self.port = reservation.getsockname()[1]
        for name in ('home', 'tmp', 'data'):
            (root / name).mkdir(mode=0o700)
        self.environment = {
            'PATH': '/usr/bin:/bin', 'HOME': str(root / 'home'), 'TMPDIR': str(root / 'tmp'),
            'LANG': 'C.UTF-8', 'PYTHONDONTWRITEBYTECODE': '1', 'PYTHONNOUSERSITE': '1',
            'VERA_DATA_DIR': str(root / 'data'), 'TASK_DB_PATH': str(root / 'data' / 'tasks.db'),
            'INTEGRATIONS_PATH': str(root / 'data' / 'integrations.json'),
            'VERA_BIND': '127.0.0.1', 'VERA_PORT': str(self.port), 'SCHEDULER_ENABLED': 'false',
            'VERA_BASE': f'http://127.0.0.1:{sentinel}/v1',
            'SEARXNG_BASE': f'http://127.0.0.1:{sentinel}/search',
        }

    def start(self) -> None:
        require(self.process is None, 'An engine process is already owned')
        command = [str(self.executable)] if self.executable else [sys.executable, '-s', str(API / 'main.py')]
        self.log = (self.root / 'engine.log').open('ab')
        try:
            self.process = subprocess.Popen(command, cwd=self.root, env=self.environment,
                                            stdin=subprocess.DEVNULL, stdout=self.log, stderr=self.log,
                                            start_new_session=True)
            eventually(self.available, seconds=35)
        except BaseException:
            self.stop()
            raise

    def available(self) -> bool:
        require(self.process is not None and self.process.poll() is None,
                'The isolated engine exited before becoming available')
        try:
            status, _ = self.request('GET', '/version')
            if status != 200 or self.identity is None:
                return False
            status, task = self.request('GET', '/tasks/' + self.identity['id'])
            return status == 200 and task == self.identity
        except (OSError, http.client.HTTPException):
            return False

    def stop(self, crash: bool = False) -> None:
        process = self.process
        self.process = None
        try:
            if process is not None:
                try:
                    os.killpg(process.pid, signal.SIGKILL if crash else signal.SIGTERM)
                except ProcessLookupError:
                    pass
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait(timeout=5)
                finally:
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                if crash:
                    require(process.returncode == -signal.SIGKILL, 'The engine was not stopped by SIGKILL')
        finally:
            if self.log is not None:
                self.log.close()
                self.log = None

    def request(self, method: str, path: str, body: Any = None,
                headers: dict[str, str] | None = None) -> tuple[int, Any]:
        connection = http.client.HTTPConnection('127.0.0.1', self.port, timeout=3)
        try:
            data = json.dumps(body).encode() if body is not None else None
            connection.request(method, path, body=data, headers={'Content-Type': 'application/json', **(headers or {})})
            response = connection.getresponse()
            payload = response.read(1_048_577)
            require(len(payload) <= 1_048_576, 'The isolated HTTP response exceeded its bound')
            return response.status, json.loads(payload) if payload else None
        finally:
            connection.close()

    def json(self, method: str, path: str, body: Any = None, expected: int = 200) -> Any:
        status, value = self.request(method, path, body)
        require(status == expected, f'Unexpected HTTP status {status} for {method} {path.split("?")[0]}')
        return value


class Stream:
    def __init__(self, engine: Engine, path: str, headers: dict[str, str] | None = None):
        self.connection = http.client.HTTPConnection('127.0.0.1', engine.port, timeout=3)
        try:
            self.connection.request('GET', path, headers=headers or {})
            self.response = self.connection.getresponse()
            require(self.response.status == 200, 'SSE connection was refused')
            require(self.response.getheader('Content-Type', '').startswith('text/event-stream'), 'SSE content type missing')
        except BaseException:
            self.close()
            raise

    def take(self, count: int) -> list[dict[str, Any]]:
        result: list[dict[str, Any]] = []
        fields: dict[str, str] = {}
        deadline = time.monotonic() + 10
        while len(result) < count:
            require(time.monotonic() < deadline, 'SSE replay exceeded its deadline')
            raw = self.response.readline(65537)
            require(bool(raw) and len(raw) <= 65536, 'SSE ended early or exceeded its frame bound')
            line = raw.decode().rstrip('\r\n')
            if not line:
                if 'data' in fields:
                    value = json.loads(fields['data'])
                    require(fields.get('event') == 'task' and int(fields['id']) == value['id'], 'SSE frame identity mismatch')
                    result.append(value)
                fields = {}
            elif not line.startswith(':'):
                name, _, value = line.partition(':')
                require(name not in fields, 'Duplicate SSE field')
                fields[name] = value.lstrip(' ')
        return result

    def close(self) -> None:
        self.connection.close()

    def __enter__(self) -> 'Stream':
        return self

    def __exit__(self, *args: Any) -> None:
        self.close()


def all_events(store: TaskStore, task_id: str | None = None) -> list[dict[str, Any]]:
    result: list[dict[str, Any]] = []
    after = 0
    while batch := store.events(after, task_id, 200):
        result.extend(batch)
        require(len(result) <= 2000 and batch[-1]['id'] > after, 'Event pagination did not make bounded progress')
        after = batch[-1]['id']
    return result


def seed(store: TaskStore) -> dict[str, dict[str, Any]]:
    saved: dict[str, dict[str, Any]] = {}
    for state in ('completed', 'needs_decision', 'blocked'):
        task = store.create('contract-fixture', {}, state)
        claimed = store.claim(('contract-fixture',))
        require(claimed is not None and claimed['id'] == task['id'], 'Fixture claim failed')
        saved[state] = store.commit_step(task['id'], claimed['generation'], StepResult(
            state=state, checkpoint={'cursor': state},
            result={'fixture': True} if state == 'completed' else None,
            decision={'prompt': 'Continue fixture?'} if state == 'needs_decision' else None))
    canceled = store.create('contract-fixture', {}, 'canceled')
    saved['canceled'] = store.cancel(canceled['id'])
    saved['queued'] = store.create('contract-fixture', {}, 'queued')
    for index in range(210):
        store.create('contract-fixture', {'index': index}, f'pagination-{index}')
    return saved


def exercise(engine: Engine, sentinel: int, requests: list[str]) -> dict[str, Any]:
    store = TaskStore(engine.environment['TASK_DB_PATH'])
    saved = seed(store)
    engine.identity = saved['queued']
    engine.start()
    try:
        binding = {'id': 'contract-native', 'admission_base': f'http://127.0.0.1:{sentinel}/v1', 'enrollment_digest': '0' * 64}
        body = {'worker_type': 'research', 'idempotency_key': 'http-create',
                'payload': {'query': 'Synthetic contract question', 'use_rag': False, 'native_binding': binding}}
        task = engine.json('POST', '/tasks', body, 201)
        task_id = task['id']
        require(engine.json('POST', '/tasks', body, 201)['id'] == task_id, 'Create replay changed task identity')
        conflict = {**body, 'payload': {**body['payload'], 'query': 'Conflicting fixture'}}
        engine.json('POST', '/tasks', conflict, 409)

        def blocked() -> Any:
            current = engine.json('GET', '/tasks/' + task_id)
            return current if current['state'] == 'blocked' else None

        waiting_native = eventually(blocked)
        require(waiting_native['checkpoint']['native_unavailable'] == binding['id'], 'Research did not block before model execution')
        ids: list[str] = []
        cursor = ''
        while True:
            page = engine.json('GET', '/tasks?limit=37' + ('&before=' + cursor if cursor else ''))['tasks']
            if not page:
                break
            ids.extend(value['id'] for value in page)
            require(len(ids) <= 216 and page[-1]['id'] != cursor, 'Task pagination did not make bounded progress')
            cursor = page[-1]['id']
        require(len(ids) == 216 and len(set(ids)) == len(ids) and task_id in ids, 'Task pagination lost or duplicated a task')

        def pending() -> Any:
            status, value = engine.request('POST', f'/tasks/{task_id}/native/ready', binding)
            require(status in (200, 204), 'Native fixture enrollment was refused')
            return value if status == 200 else None

        generation = eventually(pending)
        running = engine.json('GET', '/tasks/' + task_id)
        require(running['state'] == 'running' and running['generation'] == generation['generation'], 'Worker never entered its pending native step')
        queued = engine.json('POST', '/tasks', {**body, 'idempotency_key': 'queued-recovery'}, 201)
        require(queued['state'] == 'queued', 'Second registered task was not queued behind the active worker')
        with Stream(engine, '/tasks/events') as stream:
            received = stream.take(113)
            last_id = received[-1]['id']
            require(len(all_events(store)) > 200, 'Fixture did not cross SSE batch boundaries')
            require(pending()['generation'] == generation['generation'], 'Pending generation changed before interruption')
            engine.stop(crash=True)
        before_restart = all_events(store)
        require(store.get(task_id)['state'] == 'running', 'Killed worker did not leave a durable claim')
        require(store.get(queued['id'])['state'] == 'queued', 'Queued registered task did not survive interruption')
        engine.start()
        recovered = eventually(blocked)
        def queued_recovered() -> Any:
            current = engine.json('GET', '/tasks/' + queued['id'])
            return current if current['state'] == 'blocked' else None

        resumed_queued = eventually(queued_recovered)
        require(resumed_queued['generation'] > queued['generation']
                and resumed_queued['checkpoint']['native_unavailable'] == binding['id'],
                'Restart did not run queued registered work up to native availability')
        require(recovered['id'] == task_id and recovered['generation'] > running['generation'], 'Restart did not fence the previous generation')
        require(recovered['checkpoint'] == running['checkpoint'], 'Restart lost the committed checkpoint')
        require(all_events(store)[:len(before_restart)] == before_restart, 'Restart rewrote existing events')
        try:
            store.commit_step(task_id, running['generation'], StepResult(state='completed'))
        except TaskConflict:
            pass
        else:
            raise AssertionError('The previous worker claim survived restart')
        late = {'job_id': generation['id'], 'binding_id': binding['id'], 'generation': generation['generation'],
                'messages_digest': generation['messages_digest'], 'failure': 'provider_unavailable'}
        engine.json('POST', f'/tasks/{task_id}/native/result', late, 409)
        for state, original in saved.items():
            current = engine.json('GET', '/tasks/' + original['id'])
            require(current == original, f'Restart changed a preserved {state} task')

        expected = all_events(store)
        replay = [event for event in expected if event['id'] > last_id]
        with Stream(engine, '/tasks/events?after=0', {'Last-Event-ID': str(last_id)}) as stream:
            resumed = stream.take(len(replay))
        require(received + resumed == expected, 'SSE crash reconnect missed, duplicated or reordered committed events')
        require(len({event['id'] for event in received + resumed}) == len(expected), 'SSE replay duplicated an event')
        filtered = all_events(store, task_id)
        with Stream(engine, '/tasks/events?task_id=' + task_id) as stream:
            require(stream.take(len(filtered)) == filtered, 'SSE task filter mixed event histories')
        for value, status in [('invalid', 422), ('-1', 422), (str(expected[-1]['id'] + 100), 409)]:
            actual, _ = engine.request('GET', '/tasks/events', headers={'Last-Event-ID': value})
            require(actual == status, 'SSE cursor validation returned an unexpected status')

        decision = saved['needs_decision']
        reply = {'decision_id': decision['decision']['id'], 'idempotency_key': 'fixture-decision', 'reply': {'approved': True}}
        decision_path = '/tasks/' + decision['id'] + '/decision'
        with Stream(engine, '/tasks/events?after=' + str(expected[-1]['id'])) as stream:
            answered = engine.json('POST', decision_path, reply)
            follow = [event for event in all_events(store) if event['id'] > expected[-1]['id']]
            require(bool(follow) and stream.take(len(follow)) == follow, 'SSE did not follow newly committed decision events')
        require(answered['state'] == 'queued' and answered['decision_reply'] == reply['reply'], 'Decision did not resume the waiting task')
        checkpoint_events = all_events(store, decision['id'])
        require(engine.json('POST', decision_path, reply) == answered, 'Decision replay changed the task')
        require(all_events(store, decision['id']) == checkpoint_events, 'Decision replay appended duplicate events')
        engine.json('POST', decision_path, {**reply, 'reply': {'approved': False}}, 409)
        canceled = engine.json('POST', '/tasks/' + task_id + '/cancel')
        require(canceled['state'] == 'canceled', 'Cancel did not stop blocked work')
        cancel_events = all_events(store, task_id)
        require(engine.json('POST', '/tasks/' + task_id + '/cancel') == canceled, 'Cancel replay changed the task')
        require(all_events(store, task_id) == cancel_events, 'Cancel replay appended duplicate events')
        engine.stop()
        engine.start()
        require(engine.json('POST', '/tasks', body, 201) == canceled, 'Create identity did not survive another restart')
        require(engine.json('POST', decision_path, reply) == answered, 'Decision replay did not survive another restart')
        require(all_events(store, decision['id']) == checkpoint_events, 'Restarted decision replay appended duplicate events')
        require(engine.json('POST', '/tasks/' + task_id + '/cancel') == canceled, 'Canceled state did not survive another restart')
        require(all_events(store, task_id) == cancel_events, 'Restarted cancel replay appended duplicate events')
        require(not requests, 'A model or search request reached the tripwire')
        return {'transport': 'frozen' if engine.executable else 'source', 'tasks_paginated': len(ids),
                'events_replayed': len(expected), 'initial_stream_events': len(received),
                'sigkill_recovery': True, 'queued_recovery': True, 'checkpoint_preserved': True, 'stale_generation_rejected': True,
                'sse_exact_replay': True, 'sse_live_follow': True, 'decision_and_cancel_replay': True, 'model_requests': 0}
    finally:
        engine.stop()
        require(not requests, 'An unexpected request reached the tripwire during shutdown')


def run_contract(executable: Path | None = None) -> dict[str, Any]:
    if executable is not None:
        executable = executable.resolve(strict=True)
        require(executable.is_file() and os.access(executable, os.X_OK), 'Engine executable is not runnable')
    with tempfile.TemporaryDirectory(prefix='vera-task-contract-') as directory:
        with tripwire() as (port, requests):
            return exercise(Engine(Path(directory), executable, port), port, requests)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--engine', type=Path)
    options = parser.parse_args()
    try:
        report = run_contract(options.engine)
    except Exception as error:
        print(json.dumps({'outcome': 'failed', 'error': type(error).__name__, 'detail': str(error)}))
        raise SystemExit(1) from None
    print(json.dumps({'outcome': 'passed', **report}, sort_keys=True))


if __name__ == '__main__':
    main()
