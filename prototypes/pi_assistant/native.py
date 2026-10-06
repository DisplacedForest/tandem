import asyncio
import hashlib
import json
import os
import signal
import sqlite3
import stat
import time
import uuid
from pathlib import Path
from typing import Any, Callable

from .process import PiFailure


def encoded(value: Any) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False, allow_nan=False).encode()


def private_json(path: Path, value: Any) -> None:
    data = encoded(value)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'wb') as file:
        file.write(data)
        file.flush()
        os.fsync(file.fileno())
    directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)


def identifier(value: Any) -> str:
    if not isinstance(value, str) or str(uuid.UUID(value)) != value:
        raise PiFailure('native_identity')
    return value


class NativeMockTransport:
    def __init__(self, root: Path, binary: Path):
        if root.is_symlink():
            raise PiFailure('native_storage')
        root.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.root = root.resolve()
        if self.root.stat().st_mode & 0o077:
            raise PiFailure('native_storage')
        self.binary = binary.resolve(strict=True)
        self.sha256 = hashlib.sha256(self.binary.read_bytes()).hexdigest()
        self.requests = self.root / 'requests'
        if self.requests.is_symlink():
            raise PiFailure('native_storage')
        self.requests.mkdir(mode=0o700, exist_ok=True)
        self.state = self.root / 'host.sqlite'
        fd = os.open(self.state, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_uid != os.getuid():
                raise PiFailure('native_storage')
        finally:
            os.close(fd)
        state_was_empty = self.state.stat().st_size == 0
        self.permit_path = self.root / 'permit.json'
        if not self.permit_path.exists():
            if not state_was_empty or (self.root / 'ledger').exists():
                raise PiFailure('native_permit_missing')
            now = int(time.time())
            permit = {
                'experiment_id': str(uuid.uuid4()), 'profile_id': str(uuid.uuid4()),
                'reconciliation_id': str(uuid.uuid4()), 'issued_at': now - 1, 'expires_at': now + 600,
                'prior_test_spend_usd': '0', 'budget_usd': '1', 'max_requests': 12,
                'exclusive_test_owner': True, 'budget_scope': 'vera-tests',
                'credential_access': 'noninteractive-once', 'transport': 'mock',
                'sessions': [{'id': str(uuid.uuid4()), 'task_id': None, 'role': role}
                             for role in ('foreground', 'foreground', 'worker')],
            }
            private_json(self.permit_path, permit)
        if self.permit_path.is_symlink():
            raise PiFailure('native_storage')
        if self.permit_path.stat().st_size > 65536:
            raise PiFailure('native_storage')
        self.permit = json.loads(self.permit_path.read_bytes())
        if not isinstance(self.permit, dict) or self.permit.get('transport') != 'mock':
            raise PiFailure('native_mock_permit_required')
        with self.connect() as db:
            db.executescript('''
                CREATE TABLE IF NOT EXISTS metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS scopes(slot TEXT PRIMARY KEY,task_id TEXT NOT NULL,role TEXT NOT NULL,mode TEXT NOT NULL,UNIQUE(task_id,role));
                CREATE TABLE IF NOT EXISTS requests(id TEXT PRIMARY KEY,slot TEXT NOT NULL,state TEXT NOT NULL);
            ''')
            db.execute('INSERT OR IGNORE INTO metadata VALUES(?,?)', ('binary_sha256', self.sha256))
            if db.execute('SELECT value FROM metadata WHERE key=?', ('binary_sha256',)).fetchone()[0] != self.sha256:
                raise PiFailure('native_binary_changed')
        self.process: asyncio.subprocess.Process | None = None
        self.reader: asyncio.Task[None] | None = None
        self.ready: asyncio.Future[None] | None = None
        self.pending: dict[str, asyncio.Future[dict[str, Any]]] = {}
        self.write_lock = asyncio.Lock()
        self.closing = False
        self.failed = False

    def connect(self) -> sqlite3.Connection:
        db = sqlite3.connect(self.state, timeout=5)
        db.execute('PRAGMA journal_mode=WAL')
        db.execute('PRAGMA synchronous=FULL')
        return db

    async def start(self) -> None:
        if self.process is not None:
            raise PiFailure('native_already_started')
        self.ready = asyncio.get_running_loop().create_future()
        self.process = await asyncio.create_subprocess_exec(
            str(self.binary), '--mock-pi-stdio', '--permit', str(self.permit_path),
            '--request-permits', str(self.requests), '--ledger-root', str(self.root / 'ledger'),
            '--approved-sha256', self.sha256, stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL,
            start_new_session=True, limit=65537, env={'PATH': '/usr/bin:/bin', 'LANG': 'C.UTF-8'},
        )
        self.reader = asyncio.create_task(self._read())
        try:
            await asyncio.wait_for(asyncio.shield(self.ready), 5)
        except asyncio.CancelledError:
            await self.stop()
            raise
        except BaseException:
            await self.stop()
            raise PiFailure('native_start_failed') from None

    async def _read(self) -> None:
        assert self.process is not None and self.process.stdout is not None and self.ready is not None
        try:
            while line := await self.process.stdout.readline():
                if len(line) > 65536 or not line.endswith(b'\n'):
                    raise PiFailure('native_output_limit')
                value = json.loads(line)
                if not isinstance(value, dict):
                    raise PiFailure('native_output')
                if value == {'type': 'ready', 'transport': 'native-mock'} and not self.ready.done():
                    self.ready.set_result(None)
                    continue
                request_id = identifier(value.get('request_id'))
                future = self.pending.get(request_id)
                if future is None:
                    raise PiFailure('native_unknown_reply')
                valid = value.get('ok') is True and isinstance(value.get('content'), list)
                with self.connect() as db:
                    db.execute('UPDATE requests SET state=? WHERE id=?', ('returned_ok' if valid else 'returned_error', request_id))
                self.pending.pop(request_id)
                if not valid:
                    future.set_exception(PiFailure('native_request_refused'))
                else:
                    future.set_result(value)
        except (ValueError, KeyError, OSError, sqlite3.Error, PiFailure, asyncio.LimitOverrunError):
            self.failed = True
        finally:
            self.failed = True
            if not self.ready.done():
                self.ready.set_exception(PiFailure('native_closed'))
            for future in self.pending.values():
                if not future.done():
                    future.set_exception(PiFailure('native_unconfirmed'))
            self.pending.clear()
            await self._terminate()

    def _slot(self, task_id: str, role: str, mode: str) -> str:
        identifier(task_id)
        if role not in {'foreground', 'worker'} or mode not in {'assistant', 'focused'}:
            raise PiFailure('native_scope')
        with self.connect() as db:
            db.execute('BEGIN IMMEDIATE')
            if db.execute("SELECT 1 FROM requests WHERE state='pending'").fetchone():
                pending_slots = {row[0] for row in db.execute("SELECT slot FROM requests WHERE state='pending'")}
                active_slots = {row[0] for row in db.execute('SELECT slot FROM scopes WHERE role=?', (role,))}
                if pending_slots & active_slots:
                    raise PiFailure('native_scope_busy_or_unconfirmed')
            existing = db.execute('SELECT slot,mode FROM scopes WHERE task_id=? AND role=?', (task_id, role)).fetchone()
            if existing:
                if existing[1] != mode:
                    raise PiFailure('native_scope_mode')
                return existing[0]
            used = {row[0] for row in db.execute('SELECT slot FROM scopes')}
            slot = next((entry['id'] for entry in self.permit['sessions'] if entry['role'] == role and entry['id'] not in used), None)
            if slot is None:
                raise PiFailure('native_scope_exhausted')
            db.execute('INSERT INTO scopes VALUES(?,?,?,?)', (slot, task_id, role, mode))
            return slot

    @staticmethod
    def _messages(context: Any) -> list[dict[str, Any]]:
        if not isinstance(context, dict) or not isinstance(context.get('messages'), list):
            raise PiFailure('native_context')
        messages: list[dict[str, Any]] = []
        system = context.get('systemPrompt')
        if system:
            if not isinstance(system, str):
                raise PiFailure('native_context')
            messages.append({'role': 'system', 'content': system})
        for message in context['messages']:
            if not isinstance(message, dict):
                raise PiFailure('native_context')
            clean = {key: message[key] for key in ('role', 'content', 'toolCallId', 'toolName', 'isError') if key in message}
            messages.append(clean)
        return messages

    async def _send(self, value: dict[str, Any], written: Callable[[], None] | None = None) -> None:
        async with self.write_lock:
            if self.process is None or self.process.stdin is None or self.failed or self.closing:
                raise PiFailure('native_closed')
            self.process.stdin.write(encoded(value) + b'\n')
            if written:
                written()
            await asyncio.wait_for(self.process.stdin.drain(), 1)

    async def complete(self, event: dict[str, Any], task_id: str, role: str, mode: str) -> dict[str, Any]:
        try:
            return await self._complete(event, task_id, role, mode)
        except (sqlite3.Error, OSError, ValueError):
            raise PiFailure('native_storage_or_protocol') from None

    async def _complete(self, event: dict[str, Any], task_id: str, role: str, mode: str) -> dict[str, Any]:
        if event.get('type') != 'model' or self.failed or self.closing:
            raise PiFailure('native_unavailable')
        request_id = identifier(event.get('id'))
        slot = self._slot(task_id, role, mode)
        request = {'op': 'complete', 'request_id': request_id, 'session_id': slot,
                   'task_id': task_id, 'role': role, 'mode': mode,
                   'messages': self._messages(event.get('context'))}
        data = encoded(request)
        if len(data) > 65536:
            raise PiFailure('native_context_limit')
        with self.connect() as db:
            try:
                db.execute('BEGIN IMMEDIATE')
                if db.execute('SELECT COUNT(*) FROM requests').fetchone()[0] >= self.permit['max_requests']:
                    raise PiFailure('native_request_limit')
                db.execute('INSERT INTO requests VALUES(?,?,?)', (request_id, slot, 'pending'))
            except sqlite3.IntegrityError:
                raise PiFailure('native_duplicate') from None
        private_json(self.requests / (request_id + '.json'), {
            'request_id': request_id, 'experiment_id': self.permit['experiment_id'],
            'input_sha256': hashlib.sha256(data).hexdigest(),
        })
        future: asyncio.Future[dict[str, Any]] = asyncio.get_running_loop().create_future()
        self.pending[request_id] = future
        written = False
        def did_write() -> None:
            nonlocal written
            written = True
        try:
            await self._send(request, did_write)
            return await asyncio.wait_for(asyncio.shield(future), 35)
        except (asyncio.CancelledError, asyncio.TimeoutError):
            if future.done():
                raise
            if not written:
                raise
            try:
                await asyncio.shield(self._send({'op': 'cancel', 'request_id': request_id}))
                try:
                    await asyncio.wait_for(asyncio.shield(future), 1)
                except PiFailure:
                    pass
            except (OSError, PiFailure, asyncio.TimeoutError):
                await asyncio.shield(self.stop())
            raise
        except (OSError, ValueError):
            await self.stop()
            raise PiFailure('native_unconfirmed') from None
        finally:
            if not written:
                self.pending.pop(request_id, None)
                if not future.done():
                    future.cancel()
                try:
                    with self.connect() as db:
                        db.execute('UPDATE requests SET state=? WHERE id=?', ('unsent', request_id))
                except sqlite3.Error:
                    self.failed = True
            if future.done() and not future.cancelled():
                future.exception()

    async def _terminate(self) -> None:
        process = self.process
        if process is None:
            return
        if process.stdin is not None:
            process.stdin.close()
        try:
            await asyncio.wait_for(process.wait(), 2)
        except asyncio.TimeoutError:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            await process.wait()

    async def stop(self) -> None:
        self.closing = True
        await self._terminate()
        if self.reader is not None:
            await self.reader
