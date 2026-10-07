import ast
import asyncio
import hashlib
import json
import os
import sqlite3
import time
import uuid
from pathlib import Path
from typing import Any

from routers.task_runtime import Dispatcher
from routers.task_store import StepResult, TaskConflict, TaskStore

from .process import PiFailure, PiProcess
from .native import NativeMockTransport
from .app_model import ModelTransport


def canonical(value: Any) -> str:
    return json.dumps(value, sort_keys=True, separators=(',', ':'), allow_nan=False)


class Runtime:
    def __init__(self, root: Path, node: str, worker_delay_ms: int = 0, native_mock_helper: Path | None = None, model_transport: ModelTransport | None = None):
        if native_mock_helper and model_transport:
            raise ValueError("Choose one explicit mock transport")
        self.root = root.resolve()
        self.root.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.workspace = self.root / 'workspaces'
        root_fd = os.open(self.root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            try:
                os.mkdir('workspaces', 0o700, dir_fd=root_fd)
            except FileExistsError:
                pass
            self.workspace_fd = os.open('workspaces', os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=root_fd)
        finally:
            os.close(root_fd)
        self.store = TaskStore(str(self.root / 'tasks.sqlite'))
        self.journal = self.root / 'assistant.sqlite'
        self.model_transport = model_transport
        self.native = model_transport or (NativeMockTransport(self.root / 'native-transport', native_mock_helper) if native_mock_helper else None)
        self.transport = getattr(model_transport, 'kind', 'app-owned-mock') if model_transport else ('native-mock' if self.native else 'mock')
        self.process = PiProcess(node, Path(__file__).with_name('agent.mjs'), timeout=150 if self.native else 15)
        self.worker_delay_ms = worker_delay_ms
        self.dispatcher = Dispatcher(self.store, poll_seconds=0.02)
        self.dispatcher.register('pi_worker', self.worker, 160 if self.native else 20, ('read_file', 'write_file', 'check_python'))
        self.foreground_lock = asyncio.Lock()
        self.active: set[str] = set()
        with self.connect() as db:
            db.executescript('''
                CREATE TABLE IF NOT EXISTS turns(id TEXT PRIMARY KEY, body TEXT NOT NULL, conversation TEXT NOT NULL, state TEXT NOT NULL, answer TEXT, created REAL NOT NULL, answered REAL);
                CREATE TABLE IF NOT EXISTS attempts(task_id TEXT PRIMARY KEY, state TEXT NOT NULL, result TEXT);
                CREATE TABLE IF NOT EXISTS effects(task_id TEXT NOT NULL, path TEXT NOT NULL, digest TEXT NOT NULL, before_digest TEXT NOT NULL, state TEXT NOT NULL, PRIMARY KEY(task_id,path));
                CREATE TABLE IF NOT EXISTS deliveries(task_id TEXT PRIMARY KEY, conversation TEXT NOT NULL, body TEXT NOT NULL, created REAL NOT NULL);
                CREATE TABLE IF NOT EXISTS conversations(id TEXT PRIMARY KEY, assistant TEXT NOT NULL, mode TEXT NOT NULL);
            ''')

    def connect(self) -> sqlite3.Connection:
        db = sqlite3.connect(self.journal, timeout=5)
        db.row_factory = sqlite3.Row
        db.execute('PRAGMA journal_mode=WAL')
        db.execute('PRAGMA synchronous=FULL')
        return db

    async def start(self) -> None:
        if self.native:
            await self.native.start()
        try:
            await self.dispatcher.start()
        except BaseException:
            if self.native:
                await self.native.stop()
            raise
        with self.connect() as db:
            db.execute("UPDATE turns SET state='interrupted' WHERE state='running'")

    async def stop(self) -> None:
        try:
            if await self.dispatcher.stop():
                os.close(self.workspace_fd)
        finally:
            if self.native:
                await self.native.stop()

    def accept(self, body: dict[str, Any]) -> dict[str, Any] | None:
        encoded = canonical(body)
        with self.connect() as db:
            db.execute('BEGIN IMMEDIATE')
            row = db.execute('SELECT * FROM turns WHERE id=?', (body['message_id'],)).fetchone()
            if row:
                if row['body'] != encoded:
                    raise TaskConflict('Message identity has different content')
                if row['state'] == 'completed':
                    return json.loads(row['answer'])
                raise TaskConflict('Message is in progress or interrupted; inspect its tasks before submitting again')
            conversation = db.execute('SELECT * FROM conversations WHERE id=?', (body['conversation_id'],)).fetchone()
            if conversation and (conversation['assistant'], conversation['mode']) != (body['assistant_id'], body['mode']):
                raise TaskConflict('Conversation identity is already bound')
            db.execute('INSERT OR IGNORE INTO conversations VALUES(?,?,?)', (body['conversation_id'], body['assistant_id'], body['mode']))
            if db.execute("SELECT 1 FROM turns WHERE conversation=? AND state='running'", (body['conversation_id'],)).fetchone():
                raise TaskConflict('Conversation already has an active reply')
            db.execute('INSERT INTO turns VALUES(?,?,?,?,NULL,?,NULL)', (body['message_id'], encoded, body['conversation_id'], 'running', time.time()))
        return None

    def task_ids(self, message_id: str) -> list[str]:
        with self.store.connect() as db:
            return [r['id'] for r in db.execute('SELECT id,payload FROM tasks') if json.loads(r['payload']).get('originating_message_id') == message_id]

    async def message(self, body: dict[str, Any]) -> dict[str, Any]:
        if self.native:
            async with self.foreground_lock:
                return await self._message(body)
        return await self._message(body)

    async def _message(self, body: dict[str, Any]) -> dict[str, Any]:
        if self.model_transport is not None:
            self.native.validate_scope(body['message_id'], 'foreground', body['mode'], body['assistant_id'], body['conversation_id'])
        previous = self.accept(body)
        if previous:
            return previous
        self.active.add(body['message_id'])
        try:
            async def host(event: dict[str, Any]) -> dict[str, Any]:
                if event.get('type') == 'model' and self.native:
                    return await self.native.complete(event, body['message_id'], 'foreground', body['mode'])
                if event.get('type') != 'tool' or event.get('name') != 'delegate' or body['mode'] != 'assistant':
                    raise ValueError('Tool unavailable')
                args = event.get('args')
                if not isinstance(args, dict) or set(args) != {'objective'} or not isinstance(args['objective'], str) or not 1 <= len(args['objective']) <= 8000:
                    raise ValueError('Invalid task objective')
                payload = {key: body[key] for key in ('assistant_id', 'conversation_id')}
                payload.update(originating_message_id=body['message_id'], objective=args['objective'], workspace_ref='task-private', transport=self.transport)
                task = self.store.create('pi_worker', payload, 'pi:' + body['message_id'])
                return {'task_id': task['id'], 'state': task['state']}
            prior = self.messages(body['conversation_id'])['messages']
            history = []
            for item in prior[-16:]:
                if item['id'] == body['message_id']:
                    continue
                if item['role'] == 'user':
                    history.append({'role': 'user', 'content': item['text'], 'timestamp': 0})
                else:
                    history.append({'role': 'assistant', 'content': [{'type': 'text', 'text': item['text']}], 'api': 'vera-transport', 'provider': 'vera', 'model': 'explicit-transport', 'stopReason': 'stop', 'timestamp': 0, 'usage': {'input': 0, 'output': 0, 'cacheRead': 0, 'cacheWrite': 0, 'totalTokens': 0, 'cost': {'input': 0, 'output': 0, 'cacheRead': 0, 'cacheWrite': 0, 'total': 0}}})
            result = await self.process.run({'role': 'foreground', 'mode': body['mode'], 'text': body['text'], 'session_id': body['assistant_id'], 'transport': self.transport, 'history': history}, host)
            answer = {'message_id': body['message_id'], 'reply_id': str(uuid.uuid5(uuid.NAMESPACE_URL, body['message_id'])), 'text': result['text'], 'task_ids': self.task_ids(body['message_id'])}
            with self.connect() as db:
                db.execute("UPDATE turns SET state='completed',answer=?,answered=? WHERE id=?", (canonical(answer), time.time(), body['message_id']))
            return answer
        except BaseException:
            with self.connect() as db:
                db.execute("UPDATE turns SET state='interrupted' WHERE id=?", (body['message_id'],))
            raise
        finally:
            self.active.discard(body['message_id'])

    def project(self) -> None:
        with self.store.connect() as db:
            finished = [self.store._snapshot(r) for r in db.execute("SELECT * FROM tasks WHERE state='completed'")]
        with self.connect() as db:
            for task in finished:
                if task['worker_type'] != 'pi_worker':
                    continue
                body = {'id': 'task:' + task['id'], 'role': 'assistant', 'text': task['result']['summary'], 'task_ids': [task['id']]}
                db.execute('INSERT OR IGNORE INTO deliveries VALUES(?,?,?,?)', (task['id'], task['payload']['conversation_id'], canonical(body), task['updated_at']))

    def messages(self, conversation: str) -> dict[str, Any]:
        self.project()
        messages = []
        with self.connect() as db:
            for row in db.execute('SELECT * FROM turns WHERE conversation=? ORDER BY created,id', (conversation,)):
                body = json.loads(row['body'])
                messages.append((row['created'], {'id': row['id'], 'role': 'user', 'text': body['text'], 'task_ids': self.task_ids(row['id'])}))
                if row['answer']:
                    answer = json.loads(row['answer'])
                    messages.append((row['answered'], {'id': answer['reply_id'], 'role': 'assistant', 'text': answer['text'], 'task_ids': answer['task_ids']}))
            messages.extend((r['created'], json.loads(r['body'])) for r in db.execute('SELECT body,created FROM deliveries WHERE conversation=?', (conversation,)))
        return {'messages': [item for _, item in sorted(messages, key=lambda entry: (entry[0], entry[1]['id']))]}

    def canceled(self, task: dict[str, Any]) -> bool:
        current = self.store.get(task['id'])
        return current['cancel_requested'] or current['generation'] != task['generation'] or current['state'] != 'running'

    async def worker(self, task: dict[str, Any]) -> StepResult:
        checkpoint = task['checkpoint']
        if task['payload'].get('transport', 'mock') != self.transport:
            return StepResult(state='failed', checkpoint=checkpoint, event='transport_mismatch', data={'reason': 'original_transport_required'})
        if not checkpoint.get('approved'):
            reply = task['decision_reply']
            if reply is None:
                return StepResult(state='needs_decision', event='approval_required', decision={'prompt': 'Allow the coding worker to edit sum.py in its disposable task workspace?', 'choices': ['approve', 'decline']})
            if reply != {'approved': True}:
                return StepResult(state='failed', event='permission_denied', data={'reason': 'permission_denied'})
            return StepResult(checkpoint={'approved': True}, event='approved')
        with self.connect() as db:
            attempt = db.execute('SELECT * FROM attempts WHERE task_id=?', (task['id'],)).fetchone()
            if attempt and attempt['state'] == 'completed':
                return StepResult(state='completed', checkpoint=checkpoint, result=json.loads(attempt['result']), event='completed')
            if attempt and attempt['state'] == 'running':
                if task['decision_reply'] != {'approved': True}:
                    return StepResult(state='needs_decision', checkpoint=checkpoint, event='recovery_decision', decision={'prompt': 'The worker was interrupted. Retry in the same workspace after checking its saved edits?', 'choices': ['approve', 'decline']}) if task['decision_reply'] is None else StepResult(state='failed', checkpoint=checkpoint, event='retry_declined')
        if self.model_transport is not None:
            try:
                await self.native.wait_scope(task['id'], 'worker', 'assistant', task['payload']['assistant_id'], task['payload']['conversation_id'])
            except PiFailure:
                return StepResult(state='needs_decision', checkpoint={}, event='model_scope_required', decision={'prompt': 'The app was interrupted before work could begin. Resume this task?', 'choices': ['approve', 'decline']})
        with self.connect() as db:
            db.execute("INSERT OR REPLACE INTO attempts VALUES(?,'running',NULL)", (task['id'],))
        directory = self.workspace / task['id']
        try:
            os.mkdir(task['id'], 0o700, dir_fd=self.workspace_fd)
        except FileExistsError:
            pass
        source = directory / 'sum.py'
        directory_fd = os.open(task['id'], os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=self.workspace_fd)
        try:
            try:
                fd = os.open('sum.py', os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=directory_fd)
            except FileExistsError:
                pass
            else:
                with os.fdopen(fd, 'w') as file:
                    file.write('def add(a, b):\n    return a - b\n')
        finally:
            os.close(directory_fd)
        receipts: dict[str, dict[str, Any]] = {}
        tool_failed = False
        async def host(event: dict[str, Any]) -> dict[str, Any]:
            nonlocal tool_failed
            if self.canceled(task):
                raise PiFailure('canceled')
            if event.get('type') == 'model' and self.native:
                return await self.native.complete(event, task['id'], 'worker', 'assistant')
            if event.get('type') != 'tool':
                raise ValueError('Model transport unavailable')
            try:
                receipt = self.file_tool(task, directory, event)
            except (ValueError, OSError, SyntaxError):
                tool_failed = True
                raise ValueError('Tool failed') from None
            receipts[event['name']] = receipt
            return receipt
        try:
            output = await self.process.run({'role': 'worker', 'text': task['payload']['objective'], 'session_id': task['id'], 'transport': self.transport, 'delay_ms': self.worker_delay_ms}, host, lambda: self.canceled(task))
        except PiFailure:
            return StepResult(state='needs_decision', checkpoint=checkpoint, event='worker_interrupted', decision={'prompt': 'The worker stopped before completion. Retry after checking its saved edits?', 'choices': ['approve', 'decline']})
        if self.canceled(task):
            return StepResult(state='failed', checkpoint=checkpoint, event='canceled')
        if tool_failed or set(receipts) != {'read_file', 'write_file', 'check_python'}:
            return StepResult(state='failed', checkpoint=checkpoint, event='validation_failed', data={'reason': 'required_tool_evidence_missing'})
        current_digest = self.file_tool(task, directory, {'name': 'check_python', 'args': {'path': 'sum.py'}})['digest']
        with self.connect() as db:
            effect = db.execute('SELECT digest,state FROM effects WHERE task_id=? AND path=?', (task['id'], 'sum.py')).fetchone()
        if not effect or effect['state'] != 'applied' or effect['digest'] != current_digest or receipts['check_python'].get('digest') != current_digest:
            return StepResult(state='failed', checkpoint=checkpoint, event='validation_failed', data={'reason': 'artifact_evidence_mismatch'})
        result = {'summary': output['text'], 'artifacts': [{'kind': 'file', 'path': str(source), 'title': 'sum.py'}], 'transport': self.transport}
        with self.connect() as db:
            db.execute("UPDATE attempts SET state='completed',result=? WHERE task_id=?", (canonical(result), task['id']))
        return StepResult(state='completed', checkpoint=checkpoint, result=result, event='completed')

    def file_tool(self, task: dict[str, Any], directory: Path, event: dict[str, Any]) -> dict[str, Any]:
        args, name = event.get('args'), event.get('name')
        if not isinstance(args, dict) or args.get('path') != 'sum.py' or name not in {'read_file', 'write_file', 'check_python'}:
            raise ValueError('Tool or path not granted')
        if set(args) != ({'path', 'content'} if name == 'write_file' else {'path'}):
            raise ValueError('Invalid tool arguments')
        directory_fd = os.open(task['id'], os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=self.workspace_fd)
        try:
            fd = os.open('sum.py', os.O_RDONLY | os.O_NOFOLLOW, dir_fd=directory_fd)
            with os.fdopen(fd) as file:
                current = file.read(32769)
            if len(current) > 32768:
                raise ValueError('File exceeds limit')
            if name == 'read_file':
                return {'content': current}
            if name == 'check_python':
                ast.parse(current)
                return {'syntax_valid': True, 'digest': hashlib.sha256(current.encode()).hexdigest()}
            content = args['content']
            if not isinstance(content, str) or len(content) > 32768:
                raise ValueError('Invalid content')
            digest = hashlib.sha256(content.encode()).hexdigest()
            with self.connect() as db:
                db.execute('BEGIN IMMEDIATE')
                prior = db.execute('SELECT * FROM effects WHERE task_id=? AND path=?', (task['id'], 'sum.py')).fetchone()
                if prior:
                    if prior['digest'] != digest:
                        raise ValueError('Conflicting repeated effect')
                    if hashlib.sha256(current.encode()).hexdigest() == digest:
                        db.execute("UPDATE effects SET state='applied' WHERE task_id=? AND path=?", (task['id'], 'sum.py'))
                        return {'written': True, 'reconciled': True}
                    if prior['state'] == 'applied' or hashlib.sha256(current.encode()).hexdigest() != prior['before_digest']:
                        raise ValueError('Applied file changed externally')
                else:
                    db.execute("INSERT INTO effects VALUES(?,?,?,?,'intent')", (task['id'], 'sum.py', digest, hashlib.sha256(current.encode()).hexdigest()))
            if self.canceled(task):
                raise PiFailure('canceled')
            temporary = 'sum.py.' + uuid.uuid4().hex
            fd = os.open(temporary, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600, dir_fd=directory_fd)
            with os.fdopen(fd, 'w') as file:
                file.write(content)
                file.flush()
                os.fsync(file.fileno())
            os.rename(temporary, 'sum.py', src_dir_fd=directory_fd, dst_dir_fd=directory_fd)
            os.fsync(directory_fd)
            with self.connect() as db:
                db.execute("UPDATE effects SET state='applied' WHERE task_id=? AND path=?", (task['id'], 'sum.py'))
            return {'written': True, 'reconciled': False}
        finally:
            os.close(directory_fd)
