import argparse
import asyncio
import hmac
import os
import shutil
import socket
import stat
import sys
import time
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
from pi_assistant.app_model import ModelTransport
from pi_assistant.runtime import MESSAGE_BYTES, ContextOverflow, Runtime


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
    transport: Literal['mock', 'native-mock', 'app-owned-mock', 'app-owned-provider-fixture', 'app-owned-openrouter']


def validate_payload(payload: dict) -> None:
    WorkerPayload.model_validate(payload)


def create_app(root: Path, node: str, native_mock_helper: Path | None = None, instance_id: str | None = None, model_transport: ModelTransport | None = None, ui_capability: str | None = None) -> FastAPI:
    if (model_transport is None) != (ui_capability is None) or (ui_capability is not None and len(ui_capability) != 72):
        raise ValueError("App model transport requires its private UI capability")
    capability_deadline = time.monotonic() + 600
    runtime = Runtime(root, node, native_mock_helper=native_mock_helper, model_transport=model_transport)
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
        if ui_capability is not None and (time.monotonic() >= capability_deadline or not hmac.compare_digest(request.headers.get('authorization', '').encode(), ('Bearer ' + ui_capability).encode())):
            from fastapi.responses import JSONResponse
            return JSONResponse({'detail': 'Session authentication required'}, status_code=403)
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
        return {'protocol_version': 1, 'foreground': True, 'worker': True, 'computers': False, 'message_bytes': MESSAGE_BYTES, 'transport': 'cloud' if runtime.transport == 'app-owned-openrouter' else 'mock', 'transport_detail': runtime.transport, **({'provider': 'openrouter', 'model': 'qwen/qwen3.8-flash'} if runtime.transport == 'app-owned-openrouter' else {}), 'workspace_root': str(runtime.workspace), **({'instance_id': instance_id} if instance_id else {})}
    @app.post('/assistant/messages')
    async def message(body: Message):
        try:
            return await runtime.message(body.model_dump(mode='json'))
        except ContextOverflow as exc:
            raise HTTPException(413, str(exc)) from None
        except TaskConflict as exc:
            raise HTTPException(409, str(exc)) from None
        except PiFailure:
            raise HTTPException(503, 'Assistant interrupted; inspect saved work before retrying') from None
    @app.get('/assistant/messages')
    async def messages(conversation_id: UUID):
        return runtime.messages(str(conversation_id))
    return app


async def serve_supervised(app: FastAPI, port: int, descriptor: int) -> None:
    import uvicorn
    server = uvicorn.Server(uvicorn.Config(app, fd=descriptor, host='127.0.0.1', port=port, access_log=False, log_level='warning', timeout_graceful_shutdown=3))
    loop = asyncio.get_running_loop()
    parent_gone = asyncio.Event()
    def parent_closed() -> None:
        try:
            os.read(0, 1)
        except OSError:
            pass
        loop.remove_reader(0)
        parent_gone.set()
    async def supervise() -> None:
        await parent_gone.wait()
        while not server.started and not server.should_exit:
            await asyncio.sleep(.01)
        server.should_exit = True
    loop.add_reader(0, parent_closed)
    watcher = asyncio.create_task(supervise())
    try:
        await server.serve()
    finally:
        loop.remove_reader(0)
        watcher.cancel()
        await asyncio.gather(watcher, return_exceptions=True)


def validate_supervision(descriptor: int | None, supervised: bool, instance_id: UUID | None, port: int) -> None:
    if not supervised and descriptor is None and instance_id is None:
        return
    if not supervised or descriptor is None or instance_id is None or descriptor < 3 or not 1 <= port <= 65535:
        raise ValueError('Supervised launch requires its socket and identity')
    if not stat.S_ISFIFO(os.fstat(0).st_mode):
        raise ValueError('Supervised launch requires a parent pipe')
    with socket.fromfd(descriptor, socket.AF_INET, socket.SOCK_STREAM) as inherited:
        if inherited.getsockname() != ('127.0.0.1', port) or inherited.getsockopt(socket.SOL_SOCKET, socket.SO_TYPE) != socket.SOCK_STREAM:
            raise ValueError('Supervised socket must listen on the selected loopback port')


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--data-root', required=True, type=Path)
    parser.add_argument('--native-mock-helper', type=Path)
    parser.add_argument('--port', default=8769, type=int)
    parser.add_argument('--listen-fd', type=int)
    parser.add_argument('--supervised', action='store_true')
    parser.add_argument('--instance-id', type=UUID)
    args = parser.parse_args()
    try:
        validate_supervision(args.listen_fd, args.supervised, args.instance_id, args.port)
    except (ValueError, OSError):
        parser.error('Invalid supervised launch configuration')
    root = args.data_root.expanduser().resolve()
    if root == Path.home() or root == Path.home() / '.vera' or (Path.home() / '.vera') in root.parents:
        parser.error('Use a dedicated prototype data directory')
    node = shutil.which('node')
    if not node:
        parser.error('Node is required')
    os.umask(0o077)
    import uvicorn
    app = create_app(root, node, args.native_mock_helper, str(args.instance_id) if args.instance_id else None)
    if args.supervised:
        asyncio.run(serve_supervised(app, args.port, args.listen_fd))
    else:
        uvicorn.run(app, host='127.0.0.1', port=args.port, access_log=False, log_level='warning')


if __name__ == '__main__':
    main()
