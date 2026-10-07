import asyncio
import json
import os
from typing import Any, Protocol

from .native import NativeMockTransport, identifier
from .process import PiFailure


class ModelTransport(Protocol):
    async def start(self) -> None: ...
    async def stop(self) -> None: ...
    async def complete(self, event: dict[str, Any], task_id: str, role: str, mode: str) -> dict[str, Any]: ...


def decode_frame(data: bytes) -> dict[str, Any]:
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise ValueError('duplicate')
            result[key] = value
        return result
    if len(data) > 65536 or not data.endswith(b'\n'):
        raise PiFailure('app_frame')
    value = json.loads(data, object_pairs_hook=pairs, parse_constant=lambda _: (_ for _ in ()).throw(ValueError('number')))
    if not isinstance(value, dict):
        raise PiFailure('app_frame')
    return value


class AppModelTransport:
    def __init__(self, channel: str, profile: str, request_timeout: float = 5, kind: str = 'app-owned-mock'):
        if kind not in ('app-owned-mock', 'app-owned-provider-fixture', 'app-owned-openrouter'):
            raise PiFailure('app_transport')
        self.kind = kind
        if not isinstance(request_timeout, (float, int)) or not 1 <= request_timeout <= 35:
            raise PiFailure("app_deadline")
        self.request_timeout = request_timeout
        self.channel = identifier(channel)
        self.profile = identifier(profile)
        self.scopes: dict[tuple[str, str], dict[str, str]] = {}
        self.pending: dict[str, asyncio.Future[dict[str, Any]]] = {}
        self.seen: set[str] = set()
        self.closed = asyncio.Event()
        self.scope_changed = asyncio.Event()
        self.buffer = bytearray()
        self.started = False

    async def start(self) -> None:
        if self.started:
            raise PiFailure('app_started')
        self.started = True
        os.set_blocking(0, False)
        os.set_blocking(1, False)
        asyncio.get_running_loop().add_reader(0, self.readable)

    def readable(self) -> None:
        try:
            data = os.read(0, 4096)
            if not data:
                raise PiFailure('app_closed')
            self.buffer.extend(data)
            while b'\n' in self.buffer:
                line, _, rest = self.buffer.partition(b'\n')
                self.buffer = bytearray(rest)
                self.receive(decode_frame(bytes(line) + b'\n'))
            if len(self.buffer) > 65536:
                raise PiFailure('app_frame')
        except (OSError, ValueError, TypeError, RecursionError, PiFailure):
            self.close()

    def receive(self, frame: dict[str, Any]) -> None:
        if frame.get('op') == 'scope':
            if set(frame) != {'op', 'channel', 'binding'} or frame['channel'] != self.channel:
                raise PiFailure('app_channel')
            value = frame['binding']
            if not isinstance(value, dict) or set(value) != {'scope', 'subject', 'role', 'mode', 'profile', 'assistant', 'conversation'}:
                raise PiFailure('app_scope')
            identifier(value['scope'])
            identifier(value['subject'])
            identifier(value['assistant'])
            identifier(value['conversation'])
            if value['profile'] != self.profile or value['role'] not in {'foreground', 'worker'} or value['mode'] not in {'assistant', 'focused'} or (value['role'] == 'worker' and value['mode'] != 'assistant'):
                raise PiFailure('app_scope')
            key = (value['subject'], value['role'])
            if key in self.scopes or len(self.scopes) >= 16:
                raise PiFailure('app_scope')
            self.scopes[key] = value
            self.scope_changed.set()
            self.send({'op': 'scoped', 'channel': self.channel, 'scope': value['scope']})
        elif frame.get('op') == 'reply':
            ok = frame.get('ok')
            if type(ok) is not bool or set(frame) != {'op', 'id', 'ok', 'result' if ok else 'error'}:
                raise PiFailure('app_reply')
            future = self.pending.pop(identifier(frame['id']), None)
            if future is None or future.done():
                raise PiFailure('app_reply')
            if ok and isinstance(frame['result'], dict):
                future.set_result(frame['result'])
            else:
                future.set_exception(PiFailure('app_refused'))
        else:
            raise PiFailure('app_operation')

    def send(self, value: dict[str, Any]) -> None:
        if self.closed.is_set():
            raise PiFailure('app_closed')
        data = json.dumps(value, separators=(',', ':'), allow_nan=False).encode() + b'\n'
        if len(data) > 65536:
            raise PiFailure('app_frame')
        try:
            if os.write(1, data) != len(data):
                raise PiFailure('app_write')
        except (OSError, PiFailure):
            self.close()
            raise PiFailure('app_closed') from None

    def validate_scope(self, subject: str, role: str, mode: str, assistant: str, conversation: str) -> None:
        scope = self.scopes.get((subject, role))
        if self.closed.is_set() or scope is None or (scope['mode'], scope['assistant'], scope['conversation']) != (mode, assistant, conversation):
            raise PiFailure('app_unauthorized')

    async def wait_scope(self, subject: str, role: str, mode: str, assistant: str, conversation: str) -> None:
        async def wait() -> None:
            while (subject, role) not in self.scopes and not self.closed.is_set():
                self.scope_changed.clear()
                await self.scope_changed.wait()
            self.validate_scope(subject, role, mode, assistant, conversation)
        try:
            await asyncio.wait_for(wait(), 3)
        except asyncio.TimeoutError:
            raise PiFailure('app_scope_required') from None

    async def complete(self, event: dict[str, Any], task_id: str, role: str, mode: str) -> dict[str, Any]:
        scope = self.scopes.get((task_id, role))
        if event.get('type') != 'model' or scope is None or scope['mode'] != mode or self.closed.is_set():
            raise PiFailure('app_unauthorized')
        request_id = identifier(event.get('id'))
        if request_id in self.seen or len(self.seen) >= 12:
            raise PiFailure('app_limit')
        messages = NativeMockTransport._messages(event.get('context'))
        for message in messages:
            if message.get('role') == 'user' and isinstance(message.get('content'), list):
                blocks = message['content']
                if any(not isinstance(block, dict) or set(block) != {'type', 'text'} or block['type'] != 'text' or not isinstance(block['text'], str) for block in blocks):
                    raise PiFailure('app_text_only')
                message['content'] = ''.join(block['text'] for block in blocks)
        future = asyncio.get_running_loop().create_future()
        self.pending[request_id] = future
        self.seen.add(request_id)
        try:
            self.send({'op': 'complete', 'id': request_id, 'channel': self.channel, **scope, 'messages': messages})
            return await asyncio.wait_for(asyncio.shield(future), self.request_timeout)
        except (asyncio.CancelledError, asyncio.TimeoutError):
            if not future.done():
                self.send({'op': 'cancel', 'id': request_id, 'channel': self.channel})
                future.add_done_callback(lambda done: done.exception() if not done.cancelled() else None)
            raise
        except BaseException:
            if future.done():
                future.exception()
            raise

    def close(self) -> None:
        if self.started:
            asyncio.get_running_loop().remove_reader(0)
        self.closed.set()
        self.scope_changed.set()
        for future in self.pending.values():
            if not future.done():
                future.set_exception(PiFailure('app_unconfirmed'))
        self.pending.clear()
        self.scopes.clear()

    async def stop(self) -> None:
        self.close()
