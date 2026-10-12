import asyncio
import json
import os
from typing import Any, AsyncIterator, Callable

from fastapi import APIRouter, Header, HTTPException, Query, Request
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, Field

from .task_runtime import Dispatcher, Step, Worker
from .task_store import TaskConflict, TaskNotFound, TaskStore

router = APIRouter(prefix='/tasks', tags=['tasks'])
_runtime: Dispatcher | None = None
_workers: dict[str, Worker] = {}
_validators: dict[str, Callable[[dict[str, Any]], None]] = {}


class CreateTask(BaseModel):
    worker_type: str = Field(min_length=1, max_length=80)
    payload: dict[str, Any] = Field(default_factory=dict)
    idempotency_key: str = Field(min_length=1, max_length=200)


class DecisionReply(BaseModel):
    decision_id: str = Field(min_length=1, max_length=80)
    idempotency_key: str = Field(min_length=1, max_length=200)
    reply: dict[str, Any]


def register_worker(worker_type: str, step: Step, timeout_seconds: float, tools: tuple[str, ...] = (),
                    validate_payload: Callable[[dict[str, Any]], None] | None = None) -> None:
    if _runtime is not None or worker_type in _workers:
        raise ValueError('Register each worker once before task engine startup')
    _workers[worker_type] = Worker(step, timeout_seconds, tools)
    if validate_payload is not None:
        _validators[worker_type] = validate_payload


async def start() -> None:
    global _runtime
    if _runtime is not None:
        return
    path = os.environ.get('TASK_DB_PATH', '').strip()
    if not path:
        raise RuntimeError('Task storage must be resolved before startup')
    runtime = Dispatcher(await asyncio.to_thread(TaskStore, path))
    for worker_type, worker in _workers.items():
        runtime.register(worker_type, worker.step, worker.timeout_seconds, worker.tools)
    await runtime.start()
    _runtime = runtime


async def stop() -> None:
    global _runtime
    if _runtime is not None:
        if await _runtime.stop():
            _runtime = None


def runtime() -> Dispatcher:
    if _runtime is None or _runtime.failure is not None:
        raise HTTPException(503, 'Task engine is unavailable')
    return _runtime


async def call(method: Any, *args: Any) -> Any:
    try:
        return await asyncio.to_thread(method, *args)
    except TaskNotFound:
        raise HTTPException(404, 'Task not found') from None
    except TaskConflict as exc:
        raise HTTPException(409, str(exc)) from None
    except (ValueError, TypeError) as exc:
        raise HTTPException(422, str(exc)) from None


def compact_snapshot(task: dict[str, Any]) -> dict[str, Any]:
    compact = dict(task)
    if isinstance(compact.get('checkpoint'), dict):
        compact['checkpoint'] = {key: value for key, value in compact['checkpoint'].items() if key not in ('outline', 'drafts', 'revisions')}
    if isinstance(compact.get('result'), dict):
        compact['result'] = {key: value for key, value in compact['result'].items() if key not in ('markdown', 'report', 'display_blocks', 'spoken_text')}
    return compact


@router.get('')
async def list_tasks(limit: int = Query(100, ge=1, le=200), before: str | None = None, compact: bool = False) -> dict[str, Any]:
    engine = runtime()
    tasks = await call(engine.store.list, limit, before)
    if compact:
        tasks = [compact_snapshot(task) for task in tasks]
    return {'tasks': tasks, 'available_workers': sorted(engine.workers)}


@router.post('', status_code=201)
async def create_task(body: CreateTask) -> dict[str, Any]:
    engine = runtime()
    if body.worker_type not in engine.workers:
        raise HTTPException(503, 'This task worker is not configured')
    return await call(engine.store.create, body.worker_type, body.payload, body.idempotency_key,
                      _validators.get(body.worker_type))


async def event_stream(store: TaskStore, after: int, task_id: str | None,
                       request: Request, poll_seconds: float = 0.25) -> AsyncIterator[str]:
    idle = 0
    while not await request.is_disconnected():
        events = await asyncio.to_thread(store.events, after, task_id)
        if events:
            for event in events:
                after = event['id']
                yield f"id: {after}\nevent: task\ndata: {json.dumps(event, separators=(',', ':'))}\n\n"
            idle = 0
        else:
            idle += 1
            if idle >= max(1, int(15 / poll_seconds)):
                yield ': keepalive\n\n'
                idle = 0
            await asyncio.sleep(poll_seconds)


@router.get('/events')
async def events(request: Request, task_id: str | None = None,
                 after: int = Query(0, ge=0), last_event_id: str | None = Header(None)) -> StreamingResponse:
    store = runtime().store
    if last_event_id is not None:
        try:
            after = int(last_event_id)
            if after < 0:
                raise ValueError
        except ValueError:
            raise HTTPException(422, 'Last-Event-ID must be a nonnegative integer') from None
    if after > await call(store.latest_event_id):
        raise HTTPException(409, 'Event cursor is ahead of this task store')
    if task_id is not None:
        await call(store.get, task_id)
    return StreamingResponse(event_stream(store, after, task_id, request), media_type='text/event-stream',
                             headers={'Cache-Control': 'no-cache', 'X-Accel-Buffering': 'no'})


@router.get('/{task_id}')
async def get_task(task_id: str) -> dict[str, Any]:
    return await call(runtime().store.get, task_id)


@router.post('/{task_id}/cancel')
async def cancel_task(task_id: str) -> dict[str, Any]:
    return await call(runtime().store.cancel, task_id)


@router.post('/{task_id}/decision')
async def respond_to_decision(task_id: str, body: DecisionReply) -> dict[str, Any]:
    return await call(runtime().store.respond, task_id, body.decision_id, body.idempotency_key, body.reply)
