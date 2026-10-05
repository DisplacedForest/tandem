import asyncio
import copy
import fcntl
import logging
import math
import sqlite3
from dataclasses import dataclass
from typing import Any, Awaitable, Callable, IO

from .task_store import StepResult, TaskConflict, TaskStore

Step = Callable[[dict[str, Any]], Awaitable[StepResult]]
log = logging.getLogger('vera.tasks')


@dataclass(frozen=True)
class Worker:
    step: Step
    timeout_seconds: float
    tools: tuple[str, ...] = ()

    def __post_init__(self) -> None:
        if not math.isfinite(self.timeout_seconds) or self.timeout_seconds <= 0 or not callable(self.step):
            raise ValueError('Worker callable and a finite positive step timeout are required')
        if not isinstance(self.tools, tuple) or len(self.tools) > 32 or any(not isinstance(name, str) or not name.strip() or len(name) > 80 for name in self.tools) or len(set(self.tools)) != len(self.tools):
            raise ValueError('Declared tools must be a tuple of distinct bounded names')


class Dispatcher:
    def __init__(self, store: TaskStore, poll_seconds: float = 0.1, cancellation_grace_seconds: float = 1.0):
        if any(not math.isfinite(value) or value <= 0 for value in (poll_seconds, cancellation_grace_seconds)):
            raise ValueError('Dispatcher timing limits must be finite and positive')
        self.store = store
        self.workers: dict[str, Worker] = {}
        self.poll_seconds = poll_seconds
        self.cancellation_grace_seconds = cancellation_grace_seconds
        self.failure: str | None = None
        self._loop: asyncio.Task[None] | None = None
        self._lock: IO[str] | None = None
        self._active: asyncio.Task[StepResult] | None = None
        self._shutdown = asyncio.Event()
        self._retirement: asyncio.Task[None] | None = None

    def register(self, worker_type: str, step: Step, timeout_seconds: float, tools: tuple[str, ...] = ()) -> None:
        if self._loop is not None or worker_type in self.workers:
            raise ValueError('Register each worker once before starting the dispatcher')
        if not worker_type.strip() or len(worker_type) > 80 or not math.isfinite(timeout_seconds) or timeout_seconds <= 0:
            raise ValueError('Worker name and a finite positive step timeout are required')
        self.workers[worker_type] = Worker(step, timeout_seconds, tools)

    async def start(self) -> None:
        if self._loop is not None:
            return
        if self._lock is not None:
            raise RuntimeError('Previous task execution still owns the database')
        handle = open(self.store.path + '.lock', 'a', encoding='utf-8')
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            handle.close()
            raise RuntimeError('The task database already has an active dispatcher') from None
        self._lock = handle
        try:
            await asyncio.to_thread(self.store.recover)
            self._shutdown.clear()
            self.failure = None
            self._loop = asyncio.create_task(self._dispatch())
        except BaseException:
            self._release()
            raise

    def _release(self) -> None:
        if self._lock is not None:
            fcntl.flock(self._lock, fcntl.LOCK_UN)
            self._lock.close()
            self._lock = None

    async def stop(self) -> bool:
        self._shutdown.set()
        if self._loop is not None:
            await self._loop
            self._loop = None
        if self._active is not None and not self._active.done():
            self.failure = 'Task worker did not stop; database ownership retained until it exits'
            if self._retirement is None:
                self._retirement = asyncio.create_task(self._retire_worker())
            return False
        if self._retirement is not None:
            await self._retirement
            self._retirement = None
        if self._lock is not None:
            try:
                await asyncio.to_thread(self.store.recover)
            finally:
                self._release()
        self._active = None
        return True

    async def _retire_worker(self) -> None:
        active = self._active
        if active is None:
            return
        try:
            await asyncio.shield(active)
        except asyncio.CancelledError:
            if not active.done():
                return
        except Exception:
            pass
        try:
            await asyncio.to_thread(self.store.recover)
        finally:
            self._active = None
            self._release()

    async def _persist(self, task: dict[str, Any], outcome: StepResult) -> None:
        for attempt in range(3):
            try:
                await asyncio.to_thread(self.store.commit_step, task['id'], task['generation'], outcome)
                return
            except TaskConflict:
                current = await asyncio.to_thread(self.store.get, task['id'])
                if current['state'] != 'running' or current['generation'] != task['generation']:
                    return
                outcome = StepResult(state='failed', checkpoint=task['checkpoint'], event='failed', data={'reason': 'invalid_step_result'})
            except (TypeError, ValueError, AttributeError):
                outcome = StepResult(state='failed', checkpoint=task['checkpoint'], event='failed', data={'reason': 'invalid_step_result'})
            except (sqlite3.Error, OSError):
                if attempt == 2:
                    raise
                await asyncio.sleep(self.poll_seconds)
        raise RuntimeError('Task result could not be persisted')

    async def _run_step(self, task: dict[str, Any]) -> None:
        worker = self.workers[task['worker_type']]
        self._active = asyncio.create_task(worker.step(copy.deepcopy(task)))
        shutdown = asyncio.create_task(self._shutdown.wait())
        try:
            done, _ = await asyncio.wait({self._active, shutdown}, timeout=worker.timeout_seconds, return_when=asyncio.FIRST_COMPLETED)
            if self._shutdown.is_set():
                return
            if self._active not in done:
                self._active.cancel()
                outcome = StepResult(state='failed', checkpoint=task['checkpoint'], event='failed', data={'reason': 'step_timeout'})
            else:
                try:
                    outcome = self._active.result()
                except asyncio.CancelledError:
                    outcome = StepResult(state='failed', checkpoint=task['checkpoint'], event='failed', data={'reason': 'step_canceled'})
                except Exception:
                    outcome = StepResult(state='failed', checkpoint=task['checkpoint'], event='failed', data={'reason': 'worker_error'})
            await self._persist(task, outcome)
        finally:
            shutdown.cancel()
            await asyncio.gather(shutdown, return_exceptions=True)
            if self._active is not None:
                if not self._active.done():
                    self._active.cancel()
                    await asyncio.wait({self._active}, timeout=self.cancellation_grace_seconds)
                if self._active.done():
                    self._consume_result(self._active)
                    self._active = None
                else:
                    self.failure = 'Task worker ignored cancellation; restart after it exits'
                    self._active.add_done_callback(self._consume_result)

    async def _dispatch(self) -> None:
        try:
            while not self._shutdown.is_set() and self.failure is None:
                task = await asyncio.to_thread(self.store.claim, tuple(self.workers))
                if task is None:
                    await asyncio.sleep(self.poll_seconds)
                elif not self._shutdown.is_set():
                    await self._run_step(task)
        except Exception:
            self.failure = 'Task dispatcher unavailable; restart after resolving the storage or worker error'
            log.exception('Task dispatcher stopped; persisted claims will recover on restart')

    @staticmethod
    def _consume_result(task: asyncio.Task[StepResult]) -> None:
        if not task.cancelled():
            task.exception()
