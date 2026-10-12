from __future__ import annotations

import json
import os
import sqlite3
import time
import uuid
from contextlib import contextmanager
from dataclasses import dataclass, field
from typing import Any, Callable, Iterator, Literal

TaskState = Literal['queued', 'running', 'blocked', 'needs_decision', 'completed', 'failed', 'canceled']
TERMINAL = frozenset({'completed', 'failed', 'canceled'})
STATES = frozenset({'queued', 'running', 'blocked', 'needs_decision', *TERMINAL})
MAX_JSON_BYTES = 262144
MAX_EVENT_BYTES = 16384


class TaskConflict(ValueError):
    pass


class TaskNotFound(LookupError):
    pass


def encode(value: Any, limit: int = MAX_JSON_BYTES) -> str:
    text = json.dumps(value, sort_keys=True, separators=(',', ':'), allow_nan=False, ensure_ascii=False)
    if len(text.encode('utf-8')) > limit:
        raise ValueError('Task data exceeds its size limit')
    return text


@dataclass(frozen=True)
class StepResult:
    state: TaskState = 'queued'
    checkpoint: dict[str, Any] = field(default_factory=dict)
    result: dict[str, Any] | None = None
    event: str = 'progress'
    data: dict[str, Any] = field(default_factory=dict)
    decision: dict[str, Any] | None = None


class TaskStore:
    def __init__(self, path: str):
        self.path = os.path.realpath(os.path.expanduser(path))
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        with self.connect() as db:
            db.execute('PRAGMA journal_mode=WAL')
            if 'tasks' in {row[0] for row in db.execute("SELECT name FROM sqlite_master WHERE type='table'")} and 'request' not in {row[1] for row in db.execute('PRAGMA table_info(tasks)')}:
                db.execute('ALTER TABLE tasks ADD COLUMN request TEXT')
            db.executescript('''
                CREATE TABLE IF NOT EXISTS tasks (
                    id TEXT PRIMARY KEY, worker_type TEXT NOT NULL,
                    payload TEXT NOT NULL, creation_key TEXT NOT NULL UNIQUE,
                    state TEXT NOT NULL, checkpoint TEXT NOT NULL DEFAULT '{}',
                    result TEXT, decision TEXT, decision_reply TEXT,
                    cancel_requested INTEGER NOT NULL DEFAULT 0,
                    generation INTEGER NOT NULL DEFAULT 0,
                    queue_order INTEGER NOT NULL DEFAULT 0,
                    created_at REAL NOT NULL, updated_at REAL NOT NULL,
                    request TEXT
                );
                CREATE TABLE IF NOT EXISTS task_events (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    task_id TEXT NOT NULL REFERENCES tasks(id),
                    kind TEXT NOT NULL, state TEXT NOT NULL,
                    data TEXT NOT NULL, created_at REAL NOT NULL
                );
                CREATE INDEX IF NOT EXISTS task_events_task ON task_events(task_id, id);
                CREATE INDEX IF NOT EXISTS task_queue ON tasks(state, queue_order);
                CREATE TABLE IF NOT EXISTS task_decisions (
                    task_id TEXT NOT NULL REFERENCES tasks(id),
                    decision_id TEXT NOT NULL, reply_key TEXT NOT NULL,
                    reply TEXT NOT NULL, PRIMARY KEY(task_id, decision_id)
                );
                CREATE TRIGGER IF NOT EXISTS immutable_task_event_update
                BEFORE UPDATE ON task_events BEGIN SELECT RAISE(ABORT, 'Events are append-only'); END;
                CREATE TRIGGER IF NOT EXISTS immutable_task_event_delete
                BEFORE DELETE ON task_events BEGIN SELECT RAISE(ABORT, 'Events are append-only'); END;
            ''')

    @contextmanager
    def connect(self) -> Iterator[sqlite3.Connection]:
        db = sqlite3.connect(self.path, timeout=5, isolation_level=None)
        db.row_factory = sqlite3.Row
        db.execute('PRAGMA foreign_keys=ON')
        db.execute('PRAGMA synchronous=FULL')
        try:
            yield db
        finally:
            db.close()

    @contextmanager
    def transaction(self) -> Iterator[sqlite3.Connection]:
        with self.connect() as db:
            db.execute('BEGIN IMMEDIATE')
            try:
                yield db
                db.commit()
            except BaseException:
                db.rollback()
                raise

    @staticmethod
    def _snapshot(row: sqlite3.Row) -> dict[str, Any]:
        task = dict(row)
        task.pop('creation_key')
        task.pop('queue_order')
        for key in ('payload', 'checkpoint', 'result', 'decision', 'decision_reply'):
            task[key] = json.loads(task[key]) if task[key] is not None else None
        task['cancel_requested'] = bool(task['cancel_requested'])
        return task

    @staticmethod
    def _row(db: sqlite3.Connection, task_id: str) -> sqlite3.Row:
        row = db.execute('SELECT * FROM tasks WHERE id = ?', (task_id,)).fetchone()
        if row is None:
            raise TaskNotFound(task_id)
        return row

    def _event(self, db: sqlite3.Connection, task_id: str, kind: str,
               state: str, data: dict[str, Any]) -> int:
        if not kind or len(kind) > 80:
            raise ValueError('Invalid task event name')
        cursor = db.execute(
            'INSERT INTO task_events(task_id, kind, state, data, created_at) VALUES(?,?,?,?,?)',
            (task_id, kind, state, encode(data, MAX_EVENT_BYTES), time.time()),
        )
        return int(cursor.lastrowid)

    def create(self, worker_type: str, payload: dict[str, Any], idempotency_key: str,
               validate_payload: Callable[[dict[str, Any]], Any] | None = None) -> dict[str, Any]:
        if not worker_type.strip() or len(worker_type) > 80 or not idempotency_key.strip() or len(idempotency_key) > 200:
            raise ValueError('Worker type and idempotency key are required and must fit their limits')
        body = encode(payload)
        def normalized() -> str:
            if validate_payload is None:
                return body
            value = validate_payload(json.loads(body))
            return encode(value) if isinstance(value, dict) else body
        with self.transaction() as db:
            existing = db.execute('SELECT * FROM tasks WHERE creation_key = ?', (idempotency_key,)).fetchone()
            if existing is not None:
                if existing['worker_type'] == worker_type and body in (existing['request'], existing['payload']):
                    return self._snapshot(existing)
                try:
                    matches = existing['worker_type'] == worker_type and existing['payload'] == normalized()
                except ValueError:
                    matches = False
                if not matches:
                    raise TaskConflict('Idempotency key already used with different task data')
                return self._snapshot(existing)
            request, body = body, normalized()
            task_id, now = str(uuid.uuid4()), time.time()
            db.execute('INSERT INTO tasks(id, worker_type, payload, creation_key, state, created_at, updated_at, request) VALUES(?,?,?,?,?,?,?,?)',
                       (task_id, worker_type, body, idempotency_key, 'queued', now, now, request))
            order = self._event(db, task_id, 'created', 'queued', {})
            db.execute('UPDATE tasks SET queue_order = ? WHERE id = ?', (order, task_id))
            return self._snapshot(self._row(db, task_id))

    def get(self, task_id: str) -> dict[str, Any]:
        with self.connect() as db:
            return self._snapshot(self._row(db, task_id))

    def list(self, limit: int = 100, before: str | None = None, states: list[str] | None = None) -> list[dict[str, Any]]:
        with self.connect() as db:
            cursor = self._row(db, before) if before is not None else None
            timestamp = cursor['created_at'] if cursor is not None else None
            chosen = [state for state in (states or []) if state in STATES] or sorted(STATES)
            rows = db.execute('SELECT * FROM tasks WHERE (? IS NULL OR created_at < ? OR (created_at = ? AND id < ?)) AND state IN (' + ','.join('?' * len(chosen)) + ') ORDER BY created_at DESC, id DESC LIMIT ?',
                              (timestamp, timestamp, timestamp, before, *chosen, max(1, min(limit, 200)))).fetchall()
            return [self._snapshot(row) for row in rows]

    def events(self, after: int = 0, task_id: str | None = None, limit: int = 100) -> list[dict[str, Any]]:
        with self.connect() as db:
            rows = db.execute('SELECT * FROM task_events WHERE id > ? AND (? IS NULL OR task_id = ?) ORDER BY id LIMIT ?',
                              (after, task_id, task_id, max(1, min(limit, 200)))).fetchall()
            return [{**dict(row), 'data': json.loads(row['data'])} for row in rows]

    def latest_event_id(self) -> int:
        with self.connect() as db:
            return int(db.execute('SELECT COALESCE(MAX(id), 0) FROM task_events').fetchone()[0])

    def claim(self, worker_types: tuple[str, ...]) -> dict[str, Any] | None:
        if not worker_types:
            return None
        with self.transaction() as db:
            if db.execute("SELECT 1 FROM tasks WHERE state = 'running' LIMIT 1").fetchone():
                return None
            placeholders = ','.join('?' for _ in worker_types)
            row = db.execute(f"SELECT * FROM tasks WHERE state = 'queued' AND worker_type IN ({placeholders}) ORDER BY queue_order LIMIT 1",
                             worker_types).fetchone()
            if row is None:
                return None
            db.execute("UPDATE tasks SET state = 'running', generation = generation + 1, updated_at = ? WHERE id = ?", (time.time(), row['id']))
            self._event(db, row['id'], 'started', 'running', {})
            return self._snapshot(self._row(db, row['id']))

    def commit_step(self, task_id: str, generation: int, step: StepResult) -> dict[str, Any]:
        if step.state not in {'queued', 'blocked', 'needs_decision', 'completed', 'failed'}:
            raise TaskConflict('Invalid worker transition')
        if (step.state == 'needs_decision') != (step.decision is not None):
            raise ValueError('A decision is required only when waiting for a decision')
        if not isinstance(step.checkpoint, dict) or not isinstance(step.data, dict) or (step.result is not None and not isinstance(step.result, dict)) or (step.decision is not None and not isinstance(step.decision, dict)):
            raise ValueError('Worker checkpoint, result, event data and decision must be objects')
        checkpoint, result = encode(step.checkpoint), encode(step.result) if step.result is not None else None
        with self.transaction() as db:
            row = self._row(db, task_id)
            if row['state'] != 'running' or row['generation'] != generation:
                raise TaskConflict('Worker claim is no longer current')
            if row['cancel_requested']:
                return self._finish_cancel(db, task_id)
            decision = {**step.decision, 'id': str(uuid.uuid4())} if step.decision is not None else None
            db.execute('UPDATE tasks SET state = ?, checkpoint = ?, result = ?, decision = ?, decision_reply = NULL, updated_at = ? WHERE id = ?',
                       (step.state, checkpoint, result, encode(decision) if decision is not None else None, time.time(), task_id))
            order = self._event(db, task_id, step.event, step.state, step.data)
            db.execute('UPDATE tasks SET queue_order = ? WHERE id = ?', (order, task_id))
            return self._snapshot(self._row(db, task_id))

    def _finish_cancel(self, db: sqlite3.Connection, task_id: str) -> dict[str, Any]:
        db.execute("UPDATE tasks SET state = 'canceled', cancel_requested = 1, generation = generation + 1, decision = NULL, updated_at = ? WHERE id = ?", (time.time(), task_id))
        self._event(db, task_id, 'canceled', 'canceled', {})
        return self._snapshot(self._row(db, task_id))

    def cancel(self, task_id: str) -> dict[str, Any]:
        with self.transaction() as db:
            row = self._row(db, task_id)
            if row['state'] in TERMINAL or row['cancel_requested']:
                return self._snapshot(row)
            if row['state'] != 'running':
                return self._finish_cancel(db, task_id)
            db.execute('UPDATE tasks SET cancel_requested = 1, updated_at = ? WHERE id = ?', (time.time(), task_id))
            self._event(db, task_id, 'cancel_requested', 'running', {})
            return self._snapshot(self._row(db, task_id))

    def respond(self, task_id: str, decision_id: str, reply_key: str, reply: dict[str, Any]) -> dict[str, Any]:
        if not reply_key.strip() or len(reply_key) > 200:
            raise ValueError('A bounded reply key is required')
        body = encode(reply)
        with self.transaction() as db:
            row = self._row(db, task_id)
            prior = db.execute('SELECT * FROM task_decisions WHERE task_id = ? AND decision_id = ?', (task_id, decision_id)).fetchone()
            if prior:
                if prior['reply_key'] != reply_key or prior['reply'] != body:
                    raise TaskConflict('This decision already has a different response')
                return self._snapshot(row)
            if row['state'] != 'needs_decision' or json.loads(row['decision'])['id'] != decision_id:
                raise TaskConflict('This decision is no longer awaiting a response')
            db.execute('INSERT INTO task_decisions VALUES(?,?,?,?)', (task_id, decision_id, reply_key, body))
            db.execute("UPDATE tasks SET state = 'queued', decision = NULL, decision_reply = ?, updated_at = ? WHERE id = ?", (body, time.time(), task_id))
            order = self._event(db, task_id, 'decision_received', 'queued', {'decision_id': decision_id})
            db.execute('UPDATE tasks SET queue_order = ? WHERE id = ?', (order, task_id))
            return self._snapshot(self._row(db, task_id))

    def resume(self, task_id: str, expected_generation: int | None = None,
               checkpoint_match: dict[str, Any] | None = None) -> dict[str, Any]:
        with self.transaction() as db:
            row = self._row(db, task_id)
            if row['state'] != 'blocked' or row['cancel_requested']:
                raise TaskConflict('Only blocked tasks can be resumed')
            if expected_generation is not None and row['generation'] != expected_generation:
                raise TaskConflict('This task generation is no longer current')
            checkpoint = json.loads(row['checkpoint'])
            if checkpoint_match is not None and any(checkpoint.get(key) != value for key, value in checkpoint_match.items()):
                raise TaskConflict('This task is blocked for another reason')
            db.execute("UPDATE tasks SET state = 'queued', updated_at = ? WHERE id = ?", (time.time(), task_id))
            order = self._event(db, task_id, 'resumed', 'queued', {})
            db.execute('UPDATE tasks SET queue_order = ? WHERE id = ?', (order, task_id))
            return self._snapshot(self._row(db, task_id))

    def recover(self) -> int:
        with self.transaction() as db:
            rows = db.execute("SELECT * FROM tasks WHERE state = 'running' ORDER BY queue_order").fetchall()
            for row in rows:
                if row['cancel_requested']:
                    self._finish_cancel(db, row['id'])
                    continue
                db.execute("UPDATE tasks SET state = 'queued', generation = generation + 1, updated_at = ? WHERE id = ?", (time.time(), row['id']))
                order = self._event(db, row['id'], 'recovered', 'queued', {})
                db.execute('UPDATE tasks SET queue_order = ? WHERE id = ?', (order, row['id']))
            return len(rows)
