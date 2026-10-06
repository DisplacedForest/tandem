import argparse
import os
import shutil
import sys
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Literal
from uuid import UUID

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'services' / 'vera-api'))
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from fastapi import FastAPI, HTTPException, Request
from pydantic import BaseModel, ConfigDict, Field

from routers import tasks
from routers.task_store import TaskConflict
from pi_assistant.process import PiFailure
from pi_assistant.runtime import Runtime


class Message(BaseModel):
    model_config = ConfigDict(extra='forbid')
    assistant_id: UUID
    conversation_id: UUID
    message_id: UUID
    text: str = Field(min_length=1, max_length=8000)
    mode: Literal['assistant', 'focused']


class WorkerPayload(BaseModel):
    model_config = ConfigDict(extra='forbid')
    assistant_id: UUID
    conversation_id: UUID
    originating_message_id: UUID
    objective: str = Field(min_length=1, max_length=8000)
    workspace_ref: Literal['task-private']
    transport: Literal['mock']


def validate_payload(payload: dict) -> None:
    WorkerPayload.model_validate(payload)


def create_app(root: Path, node: str) -> FastAPI:
    runtime = Runtime(root, node)
    @asynccontextmanager
    async def lifespan(app: FastAPI):
        await runtime.start()
        tasks._runtime = runtime.dispatcher
        try:
            yield
        finally:
            await runtime.stop()
            tasks._runtime = None
    app = FastAPI(lifespan=lifespan)
    app.state.runtime = runtime
    @app.middleware('http')
    async def local_boundary(request: Request, call_next):
        if request.headers.get('origin') or request.headers.get('host', '').split(':')[0] not in {'127.0.0.1', 'localhost', 'testserver'}:
            from fastapi.responses import JSONResponse
            return JSONResponse({'detail': 'Local native client only'}, status_code=403)
        if request.method == 'POST' and request.headers.get('content-type', '').split(';')[0] != 'application/json':
            from fastapi.responses import JSONResponse
            return JSONResponse({'detail': 'JSON required'}, status_code=415)
        return await call_next(request)
    tasks._validators['pi_worker'] = validate_payload
    app.include_router(tasks.router)
    @app.get('/assistant/capabilities')
    async def capabilities():
        return {'protocol_version': 1, 'foreground': True, 'worker': True, 'computers': False, 'transport': 'mock', 'workspace_root': str(runtime.workspace)}
    @app.post('/assistant/messages')
    async def message(body: Message):
        try:
            return await runtime.message(body.model_dump(mode='json'))
        except TaskConflict as exc:
            raise HTTPException(409, str(exc)) from None
        except PiFailure:
            raise HTTPException(503, 'Assistant interrupted; inspect saved work before retrying') from None
    @app.get('/assistant/messages')
    async def messages(conversation_id: UUID):
        return runtime.messages(str(conversation_id))
    return app


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--data-root', required=True, type=Path)
    parser.add_argument('--port', default=8769, type=int)
    args = parser.parse_args()
    root = args.data_root.expanduser().resolve()
    if root == Path.home() or root == Path.home() / '.vera' or (Path.home() / '.vera') in root.parents:
        parser.error('Use a dedicated prototype data directory')
    node = shutil.which('node')
    if not node:
        parser.error('Node is required')
    os.umask(0o077)
    import uvicorn
    uvicorn.run(create_app(root, node), host='127.0.0.1', port=args.port, access_log=False, log_level='warning')


if __name__ == '__main__':
    main()
