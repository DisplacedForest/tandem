from __future__ import annotations

import fcntl
import hashlib
import json
import math
import os
import stat
import threading
import time
import unicodedata
import uuid
from pathlib import Path
from typing import Any, Callable
from urllib.parse import urlsplit

from routers.task_store import StepResult, TaskConflict, TaskStore


WORKER = 'synthetic_confirmed_invocation'
FORMAT = 'vera-prepared-invocation-fixture-v1'
FIELDS = frozenset({'hostOriginID', 'operationID', 'assistantID', 'conversationID', 'serverID', 'endpoint', 'tool', 'schemaJSON', 'argumentsJSON', 'permissionRevision', 'authorizationGeneration', 'expiresAtMilliseconds'})
SCOPE = ('hostOriginID', 'assistantID', 'conversationID')
POLICY = ('serverID', 'endpoint', 'tool', 'schemaJSON', 'permissionRevision', 'authorizationGeneration')
SYNTHETIC_SCHEMA = {'type': 'object', 'properties': {'value': {'type': 'string', 'maxLength': 200}}, 'required': ['value'], 'additionalProperties': False}


class InvocationDenied(ValueError):
    pass


def canonical(value: Any) -> str:
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=True, allow_nan=False)


def digest(value: Any) -> str:
    if isinstance(value, dict) and set(value) == FIELDS:
        pieces = [str(value[key]).encode() for key in sorted(FIELDS)]
        return hashlib.sha256(b''.join(str(len(piece)).encode() + b':' + piece for piece in pieces)).hexdigest()
    return hashlib.sha256(canonical(value).encode()).hexdigest()


def strict_json(text: str, maximum_bytes: int = 8192) -> Any:
    def pairs(items: list[tuple[str, Any]]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        seen: set[str] = set()
        for key, value in items:
            normalized = unicodedata.normalize('NFC', key)
            if normalized in seen:
                raise InvocationDenied('Ambiguous JSON key')
            seen.add(normalized)
            result[key] = value
        return result

    def invalid(_: str) -> Any:
        raise InvocationDenied('Invalid JSON number')

    if not isinstance(text, str) or len(text.encode()) > maximum_bytes:
        raise InvocationDenied('Invalid JSON size')
    try:
        value = json.loads(text, object_pairs_hook=pairs, parse_constant=invalid)
    except (ValueError, RecursionError) as error:
        raise InvocationDenied('Invalid JSON') from error
    pending = [(value, 0)]
    while pending:
        item, depth = pending.pop()
        if depth > 20:
            raise InvocationDenied('JSON is too deep')
        if isinstance(item, float) and not math.isfinite(item):
            raise InvocationDenied('Invalid JSON number')
        if isinstance(item, dict):
            pending.extend((child, depth + 1) for child in item.values())
        elif isinstance(item, list):
            pending.extend((child, depth + 1) for child in item)
    return value


def validate_binding(binding: dict[str, Any]) -> dict[str, Any]:
    if not isinstance(binding, dict) or set(binding) != FIELDS:
        raise InvocationDenied('Invalid invocation binding')
    result = dict(binding)
    for key in FIELDS - {'expiresAtMilliseconds'}:
        value = result[key]
        limit = 8192 if key.endswith('JSON') else 2048 if key == 'endpoint' else 200
        if not isinstance(value, str) or not value or len(value.encode()) > limit or any(ord(c) < 32 for c in value):
            raise InvocationDenied('Invalid invocation field')
    deadline = result['expiresAtMilliseconds']
    if type(deadline) is not int or deadline <= 0:
        raise InvocationDenied('Invalid invocation deadline')
    url = urlsplit(result['endpoint'])
    if url.scheme != 'https' or not url.hostname or url.username is not None or url.password is not None or url.fragment:
        raise InvocationDenied('Invalid invocation destination')
    schema = strict_json(result['schemaJSON'])
    args = strict_json(result['argumentsJSON'])
    if not isinstance(schema, dict) or schema.get('type') != 'object' or not isinstance(args, dict):
        raise InvocationDenied('Object schema and arguments required')
    return result


class FixtureInvocationAuthority:
    def __init__(self, binding: dict[str, Any]):
        binding = validate_binding(binding)
        self.lock = threading.RLock()
        self.scope = {key: binding[key] for key in SCOPE}
        self.policy = {key: binding[key] for key in POLICY}
        self.active = True

    def check(self, binding: dict[str, Any]) -> None:
        with self.lock:
            if not self.active or self.scope != {key: binding[key] for key in SCOPE} or self.policy != {key: binding[key] for key in POLICY}:
                raise InvocationDenied('Invocation authority changed')
            args = strict_json(binding['argumentsJSON'])
            if strict_json(binding['schemaJSON']) != SYNTHETIC_SCHEMA or binding['tool'] != 'fixture.record' or set(args) != {'value'} or not isinstance(args['value'], str) or len(args['value']) > 200:
                raise InvocationDenied('Only the explicit synthetic effect is supported')

    def revoke(self) -> None:
        with self.lock:
            self.active = False


class FixtureDecisionHost:
    def __init__(self, fixture: ConfirmedInvocationFixture, capability: object):
        self._fixture = fixture
        self._capability = capability

    def respond(self, scope: dict[str, str], task_id: str, decision_id: str, reply_key: str, approved: bool) -> dict[str, Any]:
        return self._fixture._respond(self._capability, scope, task_id, decision_id, reply_key, approved)


class ConfirmedInvocationFixture:
    def __init__(self, root: Path, authority: FixtureInvocationAuthority, *, create: bool):
        self.root = root.absolute()
        self.lock = threading.RLock()
        self.closed = False
        if self.root != self.root.resolve():
            raise InvocationDenied('Fixture root must not use symlinks')
        if create:
            self.root.mkdir(mode=0o700, parents=False, exist_ok=False)
            descriptor = os.open(self.root / 'fixture.json', os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(descriptor, 'w') as marker:
                marker.write(canonical({'format': FORMAT}))
        if self.root.is_symlink() or not self.root.is_dir() or (self.root / 'fixture.json').is_symlink():
            raise InvocationDenied('Explicit fixture root required')
        root_stat = self.root.stat()
        if root_stat.st_uid != os.getuid() or root_stat.st_mode & 0o077:
            raise InvocationDenied('Private owned fixture root required')
        for path in self.root.iterdir():
            entry = path.lstat()
            if not stat.S_ISREG(entry.st_mode) or entry.st_nlink != 1 or entry.st_uid != os.getuid() or entry.st_mode & 0o077:
                raise InvocationDenied('Private owned regular fixture files required')
        descriptor = os.open(self.root / 'fixture.json', os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(descriptor, 'r') as marker:
            marker_text = marker.read(256)
        if marker_text != canonical({'format': FORMAT}):
            raise InvocationDenied('Explicit fixture marker required')
        self._lock_file = os.fdopen(os.open(self.root / 'owner.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600), 'a+b')
        try:
            fcntl.flock(self._lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BaseException:
            self._lock_file.close()
            raise
        try:
            database = self.root / 'tasks.sqlite'
            if any(path.is_symlink() for path in self.root.iterdir()):
                raise InvocationDenied('Fixture files must not be symlinks')
            if not create:
                import sqlite3
                with sqlite3.connect(f'file:{database}?mode=ro', uri=True) as check:
                    tables = {row[0] for row in check.execute("SELECT name FROM sqlite_master WHERE type='table'")}
                if not {'invocation_effects', 'synthetic_effects', 'tasks', 'task_decisions', 'task_events'} <= tables:
                    raise InvocationDenied('Existing fixture schema required')
            else:
                os.close(os.open(database, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600))
            self.store = TaskStore(str(database))
            if create:
                with self.store.transaction() as db:
                    db.execute('CREATE TABLE invocation_effects(task_id TEXT PRIMARY KEY REFERENCES tasks(id), binding_digest TEXT NOT NULL, state TEXT NOT NULL, result TEXT)')
                    db.execute('CREATE TABLE synthetic_effects(task_id TEXT PRIMARY KEY REFERENCES tasks(id), value TEXT NOT NULL)')
            self.authority = authority
            self.epoch = str(uuid.uuid4())
            self._capability = object()
            self.decisions = FixtureDecisionHost(self, self._capability)
            self.deadlines: dict[str, float] = {}
            self.store.recover()
        except BaseException:
            self._lock_file.close()
            raise

    def close(self) -> None:
        with self.lock:
            self.closed = True
            self.deadlines.clear()
            self._lock_file.close()

    def _open(self) -> None:
        if self.closed:
            raise InvocationDenied('Fixture ownership ended')

    def _scope(self, binding: dict[str, Any], scope: dict[str, str]) -> None:
        if scope != {key: binding[key] for key in SCOPE}:
            raise InvocationDenied('Invocation scope mismatch')

    def _current(self, task: dict[str, Any]) -> None:
        self._open()
        binding = task['payload']['binding']
        self.authority.check(binding)
        if task['payload']['epoch'] != self.epoch or task['cancel_requested'] or time.time() * 1000 >= binding['expiresAtMilliseconds'] or time.monotonic() >= self.deadlines.get(task['id'], 0):
            raise InvocationDenied('Invocation authority expired')

    def _receipt(self, task: dict[str, Any]) -> dict[str, Any]:
        with self.store.connect() as db:
            effect = db.execute('SELECT state,result FROM invocation_effects WHERE task_id=?', (task['id'],)).fetchone()
        result = task['result']
        if effect:
            phase = 'effect_completed' if effect['state'] == 'completed' else 'effect_uncertain'
            result = json.loads(effect['result']) if effect['result'] is not None else None
        elif task['state'] in {'failed', 'canceled'}:
            phase = 'declined' if task['state'] == 'failed' else 'canceled'
        else:
            try:
                self._current(task)
                phase = 'awaiting_decision' if task['state'] == 'needs_decision' else 'ready' if task['checkpoint'].get('approved') is True else 'preparing'
            except InvocationDenied:
                phase = 'stale'
        return {'taskID': task['id'], 'binding': task['payload']['binding'], 'bindingDigest': digest(task['payload']['binding']), 'state': task['state'], 'phase': phase, 'decisionID': task['decision']['id'] if task['decision'] else None, 'result': result}

    def _pump(self) -> None:
        while task := self.store.claim((WORKER,)):
            checkpoint = task['checkpoint']
            try:
                self._current(task)
            except InvocationDenied:
                self.store.commit_step(task['id'], task['generation'], StepResult(state='blocked', checkpoint=checkpoint, event='invocation_stale'))
                continue
            if not checkpoint:
                self.store.commit_step(task['id'], task['generation'], StepResult(state='needs_decision', checkpoint={'binding_digest': digest(task['payload']['binding'])}, event='invocation_prepared', decision={'prompt': 'Record this value in the isolated synthetic fixture?', 'choices': ['approve', 'decline'], 'preview': {'destination': task['payload']['binding']['endpoint'], 'tool': task['payload']['binding']['tool'], 'arguments': strict_json(task['payload']['binding']['argumentsJSON'])}}))
            elif task['decision_reply'] is not None:
                approved = task['decision_reply'] == {'approved': True, 'binding_digest': digest(task['payload']['binding'])}
                self.store.commit_step(task['id'], task['generation'], StepResult(state='blocked' if approved else 'failed', checkpoint={**checkpoint, 'approved': approved}, event='invocation_ready' if approved else 'invocation_declined'))
            else:
                self.store.commit_step(task['id'], task['generation'], StepResult(state='blocked', checkpoint=checkpoint, event='invocation_uncertain'))

    def prepare(self, binding: dict[str, Any]) -> dict[str, Any]:
        binding = validate_binding(binding)
        with self.lock:
            self._open()
            self.authority.check(binding)
            key = 'prepared:' + digest({key: binding[key] for key in (*SCOPE, 'operationID')})
            with self.store.connect() as db:
                existing = db.execute('SELECT id,payload FROM tasks WHERE creation_key=?', (key,)).fetchone()
            if existing:
                if json.loads(existing['payload'])['binding'] != binding:
                    raise TaskConflict('Invocation identity already binds another request')
                return self._receipt(self.store.get(existing['id']))
            remaining = binding['expiresAtMilliseconds'] / 1000 - time.time()
            if not 0 < remaining <= 3600:
                raise InvocationDenied('Invocation deadline must be within one hour')
            task = self.store.create(WORKER, {'binding': binding, 'epoch': self.epoch}, key)
            self.deadlines[task['id']] = time.monotonic() + remaining
            self._pump()
            return self._receipt(self.store.get(task['id']))

    def inspect(self, scope: dict[str, str], task_id: str) -> dict[str, Any]:
        with self.lock:
            self._open()
            task = self.store.get(task_id)
            self._scope(task['payload']['binding'], scope)
            return self._receipt(task)

    def _respond(self, capability: object, scope: dict[str, str], task_id: str, decision_id: str, reply_key: str, approved: bool) -> dict[str, Any]:
        if capability is not self._capability or type(approved) is not bool:
            raise InvocationDenied('Explicit host decision required')
        with self.lock:
            self._open()
            task = self.store.get(task_id)
            self._scope(task['payload']['binding'], scope)
            self._current(task)
            self.store.respond(task_id, decision_id, reply_key, {'approved': approved, 'binding_digest': digest(task['payload']['binding'])})
            self._pump()
            return self.inspect(scope, task_id)

    def cancel(self, scope: dict[str, str], task_id: str) -> dict[str, Any]:
        with self.lock:
            self._open()
            task = self.store.get(task_id)
            self._scope(task['payload']['binding'], scope)
            return self._receipt(self.store.cancel(task_id))

    def dispatch_synthetic(self, scope: dict[str, str], task_id: str, *, before_effect: Callable[[], None] | None = None, after_effect: Callable[[], None] | None = None) -> dict[str, Any]:
        with self.lock:
            self._open()
            task = self.store.get(task_id)
            binding = task['payload']['binding']
            self._scope(binding, scope)
            with self.store.connect() as db:
                prior = db.execute('SELECT * FROM invocation_effects WHERE task_id=?', (task_id,)).fetchone()
            if prior:
                if prior['binding_digest'] != digest(binding):
                    raise InvocationDenied('Effect identity mismatch')
                if prior['state'] == 'completed':
                    self._settle_completed(task, json.loads(prior['result']))
                    return json.loads(prior['result'])
                raise InvocationDenied('Effect outcome requires inspection; replay is disabled')
            self._current(task)
            if task['state'] != 'blocked' or task['checkpoint'] != {'binding_digest': digest(binding), 'approved': True}:
                raise InvocationDenied('A current per-action decision is required')
            with self.store.transaction() as db:
                row = db.execute('SELECT * FROM tasks WHERE id=?', (task_id,)).fetchone()
                if row['generation'] != task['generation'] or row['cancel_requested'] or row['state'] != 'blocked':
                    raise InvocationDenied('Task authority changed')
                db.execute("INSERT INTO invocation_effects VALUES(?,?,'intent',NULL)", (task_id, digest(binding)))
        if before_effect:
            before_effect()
        with self.lock:
            with self.authority.lock:
                self._current(self.store.get(task_id))
                with self.store.transaction() as db:
                    row = db.execute('SELECT * FROM tasks WHERE id=?', (task_id,)).fetchone()
                    if row['generation'] != task['generation'] or row['cancel_requested'] or row['state'] != 'blocked':
                        raise InvocationDenied('Task authority changed')
                    self._current(task)
                    db.execute('INSERT INTO synthetic_effects VALUES(?,?)', (task_id, strict_json(binding['argumentsJSON'])['value']))
        if after_effect:
            after_effect()
        with self.lock:
            with self.authority.lock:
                self._current(self.store.get(task_id))
                result = {'status': 'completed', 'summary': 'Recorded the value in the isolated synthetic fixture.'}
                with self.store.transaction() as db:
                    row = db.execute('SELECT * FROM tasks WHERE id=?', (task_id,)).fetchone()
                    if row['generation'] != task['generation'] or row['cancel_requested'] or row['state'] != 'blocked':
                        raise InvocationDenied('Task authority changed')
                    self._current(task)
                    db.execute("UPDATE invocation_effects SET state='completed',result=? WHERE task_id=? AND state='intent'", (canonical(result), task_id))
                self._settle_completed(task, result)
                return result

    def _settle_completed(self, task: dict[str, Any], result: dict[str, Any]) -> None:
        if task['state'] in {'completed', 'canceled', 'failed'} or task['cancel_requested']:
            return
        self._pump()
        task = self.store.get(task['id'])
        if task['state'] != 'blocked':
            raise InvocationDenied('Unexpected fixture completion state')
        self.store.resume(task['id'], task['generation'], task['checkpoint'])
        claimed = self.store.claim((WORKER,))
        if claimed is None or claimed['id'] != task['id']:
            raise InvocationDenied('Unexpected fixture queue state')
        self.store.commit_step(task['id'], claimed['generation'], StepResult(state='completed', checkpoint=task['checkpoint'], result=result, event='invocation_completed'))

    def effect_count(self) -> int:
        with self.lock:
            self._open()
            with self.store.connect() as db:
                return db.execute('SELECT COUNT(*) FROM synthetic_effects').fetchone()[0]
