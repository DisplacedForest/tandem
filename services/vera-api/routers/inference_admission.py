from __future__ import annotations

import asyncio
import contextvars
import hashlib
import json
import math
import os
import re
import threading
import time
import uuid
from dataclasses import dataclass, field
from enum import Enum
from typing import Any, Awaitable, Callable, Literal, TypeVar
from urllib.parse import quote, urlsplit

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, ConfigDict, Field

from .task_store import TaskStore

Priority = Literal['foreground', 'background']
T = TypeVar('T')
priority_context: contextvars.ContextVar[Priority] = contextvars.ContextVar('inference_priority', default='foreground')
router = APIRouter(prefix='/inference/admission', tags=['inference'])
_policy: AdmissionPolicy | None = None
_managed = False


class ResearchBudget(Enum):
    PLAN = 'plan'
    SYNTHESIS = 'synthesize'


class AdmissionUnavailable(RuntimeError):
    pass


def endpoint_resource(base: str) -> str:
    parts = urlsplit(base)
    if parts.scheme.lower() not in {'http', 'https'} or not parts.hostname:
        raise ValueError('A valid model endpoint is required')
    host = parts.hostname.lower()
    if ':' in host:
        host = f'[{host}]'
    port = parts.port
    authority = host + (f':{port}' if port is not None and port != {'http': 80, 'https': 443}[parts.scheme.lower()] else '')
    path = re.sub(r'%(?![0-9a-fA-F]{2})', '%25', parts.path.rstrip('/'))
    path = quote(path, safe="/!$&'()*+,-.:;=@_~%")
    unreserved = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~'
    path = re.sub(r'%([0-9a-fA-F]{2})', lambda match: chr(int(match[1], 16)) if chr(int(match[1], 16)) in unreserved else '%' + match[1].upper(), path)
    canonical = f'{parts.scheme.lower()}://{authority}{path}'
    return hashlib.sha256(canonical.encode('utf-8')).hexdigest()


@dataclass(frozen=True)
class Settings:
    background_slots: int = 1
    background_seconds: float = 20.0
    research_plan_seconds: float = 30.0
    research_synthesis_seconds: float = 60.0
    foreground_seconds: float = 600.0
    cleanup_seconds: float = 2.0
    pending_seconds: float = 10.0
    poll_seconds: float = 0.05
    groups: dict[str, str] = field(default_factory=dict)

    def __post_init__(self) -> None:
        if not isinstance(self.background_slots, int) or not 1 <= self.background_slots <= 32:
            raise ValueError('Background generation slots must be between 1 and 32')
        if any(not math.isfinite(value) or value <= 0 for value in (self.background_seconds, self.foreground_seconds, self.cleanup_seconds, self.pending_seconds, self.poll_seconds)):
            raise ValueError('Inference timing settings must be finite and positive')
        if any(not math.isfinite(value) or not 0 < value <= 90 for value in (self.research_plan_seconds, self.research_synthesis_seconds)):
            raise ValueError('Research generation budgets must be positive and at most 90 seconds')
        if self.poll_seconds >= self.pending_seconds:
            raise ValueError('Admission polling must be shorter than the pending lifetime')
        if not isinstance(self.groups, dict) or any(len(key) != 64 or any(c not in '0123456789abcdef' for c in key) or not isinstance(value, str) or not value or len(value) > 80 for key, value in self.groups.items()):
            raise ValueError('Resource groups map endpoint fingerprints to bounded group names')

    @classmethod
    def environment(cls) -> Settings:
        legacy = os.environ.get('INFERENCE_BACKGROUND_SECONDS')
        plan = str(min(float(legacy), 90)) if legacy is not None else '30'
        synthesis = str(min(float(legacy), 90)) if legacy is not None else '60'
        return cls(
            background_slots=int(os.environ.get('INFERENCE_BACKGROUND_SLOTS', '1')),
            background_seconds=float(os.environ.get('INFERENCE_BACKGROUND_SECONDS', '20')),
            research_plan_seconds=float(os.environ.get('INFERENCE_RESEARCH_PLAN_SECONDS', plan)),
            research_synthesis_seconds=float(os.environ.get('INFERENCE_RESEARCH_SYNTHESIS_SECONDS', synthesis)),
            foreground_seconds=float(os.environ.get('INFERENCE_FOREGROUND_SECONDS', '600')),
            cleanup_seconds=float(os.environ.get('INFERENCE_CLEANUP_SECONDS', '2')),
            pending_seconds=float(os.environ.get('INFERENCE_PENDING_SECONDS', '10')),
            groups=json.loads(os.environ.get('INFERENCE_RESOURCE_GROUPS', '{}')),
        )


class AdmissionPolicy:
    def __init__(self, store: TaskStore, settings: Settings = Settings(),
                 wall: Callable[[], float] = time.time, monotonic: Callable[[], float] = time.monotonic):
        self.store = store
        self.settings = settings
        self.wall = wall
        self.monotonic = monotonic
        self._mutex = threading.Lock()
        self._deadlines: dict[str, tuple[float, float]] = {}
        with store.transaction() as db:
            db.executescript('''
                CREATE TABLE IF NOT EXISTS inference_leases (
                    id TEXT PRIMARY KEY, resource TEXT NOT NULL, priority TEXT NOT NULL,
                    requested_seconds REAL NOT NULL, state TEXT NOT NULL,
                    created_at REAL NOT NULL, updated_at REAL NOT NULL,
                    deadline REAL NOT NULL, expires_at REAL NOT NULL
                );
                CREATE INDEX IF NOT EXISTS inference_resource ON inference_leases(resource, state, created_at);
            ''')
        with self._mutex, store.transaction() as db:
            self._expire(db)

    def _remaining(self, row: Any) -> tuple[float, float]:
        if row['id'] not in self._deadlines:
            duration = row['requested_seconds'] if row['state'] == 'admitted' else self.settings.pending_seconds
            now = self.monotonic()
            wall = self.wall()
            self._deadlines[row['id']] = (
                now + max(0.0, min(duration, row['deadline'] - wall)),
                now + max(0.0, min(duration + self.settings.cleanup_seconds, row['expires_at'] - wall)),
            )
        generation, expiry = self._deadlines[row['id']]
        now = self.monotonic()
        return max(0.0, generation - now), max(0.0, expiry - now)

    def _expire(self, db: Any) -> None:
        for row in db.execute("SELECT * FROM inference_leases WHERE state IN ('pending','admitted')").fetchall():
            if self._remaining(row)[1] <= 0:
                db.execute("UPDATE inference_leases SET state = 'expired', updated_at = ? WHERE id = ?", (self.wall(), row['id']))
                self._deadlines.pop(row['id'], None)

    def _view(self, row: Any) -> dict[str, Any]:
        generation, expiry = self._remaining(row) if row['state'] in {'pending', 'admitted'} else (0.0, 0.0)
        return {'request_id': row['id'], 'state': row['state'], 'generation_seconds_remaining': generation,
                'lease_seconds_remaining': expiry, 'poll_seconds': self.settings.poll_seconds,
                'queue_seconds': max(self.settings.background_seconds, self.settings.research_plan_seconds, self.settings.research_synthesis_seconds) + self.settings.cleanup_seconds + self.settings.pending_seconds,
                'queue_wait_seconds': max(0.0, row['deadline'] - row['requested_seconds'] - row['created_at']) if row['state'] == 'admitted' else 0.0}

    def request(self, request_id: str, resource: str, priority: Priority, requested_seconds: float,
                research_budget: ResearchBudget | None = None) -> dict[str, Any]:
        if priority not in {'foreground', 'background'} or not math.isfinite(requested_seconds) or requested_seconds <= 0:
            raise ValueError('A priority and finite positive request duration are required')
        if research_budget is not None and (not isinstance(research_budget, ResearchBudget) or priority != 'background'):
            raise ValueError('Research budgets require a typed background request')
        ceiling = self.settings.background_seconds if priority == 'background' else self.settings.foreground_seconds
        if research_budget is not None:
            ceiling = self.settings.research_plan_seconds if research_budget == ResearchBudget.PLAN else self.settings.research_synthesis_seconds
        duration = min(requested_seconds, ceiling)
        resource = self.settings.groups.get(resource, resource)
        with self._mutex, self.store.transaction() as db:
            self._expire(db)
            row = db.execute('SELECT * FROM inference_leases WHERE id = ?', (request_id,)).fetchone()
            if row is not None:
                if row['state'] == 'canceled' and row['resource'] == '':
                    return self._view(row)
                if row['resource'] != resource or row['priority'] != priority or row['requested_seconds'] != duration:
                    raise ValueError('Admission request identity cannot be reused with different arguments')
                if row['state'] != 'pending':
                    return self._view(row)
            now, mono = self.wall(), self.monotonic()
            pending_until = now + self.settings.pending_seconds
            if row is None:
                db.execute('INSERT INTO inference_leases VALUES(?,?,?,?,?,?,?,?,?)',
                           (request_id, resource, priority, duration, 'pending', now, now, pending_until, pending_until))
            else:
                db.execute('UPDATE inference_leases SET updated_at = ?, deadline = ?, expires_at = ? WHERE id = ?',
                           (now, pending_until, pending_until, request_id))
            self._deadlines[request_id] = (mono + self.settings.pending_seconds, mono + self.settings.pending_seconds)
            active_background = db.execute("SELECT count(*) FROM inference_leases WHERE resource = ? AND state = 'admitted' AND priority = 'background'", (resource,)).fetchone()[0]
            foreground = db.execute("SELECT 1 FROM inference_leases WHERE resource = ? AND state IN ('pending','admitted') AND priority = 'foreground' LIMIT 1", (resource,)).fetchone()
            oldest = db.execute("SELECT id FROM inference_leases WHERE resource = ? AND state = 'pending' AND priority = 'background' ORDER BY created_at, rowid LIMIT 1", (resource,)).fetchone()
            permitted = (priority == 'foreground' and active_background == 0) or (
                priority == 'background' and not foreground and active_background < self.settings.background_slots and oldest is not None and oldest['id'] == request_id)
            if permitted:
                deadline, expiry = now + duration, now + duration + self.settings.cleanup_seconds
                db.execute("UPDATE inference_leases SET state = 'admitted', deadline = ?, expires_at = ?, updated_at = ? WHERE id = ?", (deadline, expiry, now, request_id))
                self._deadlines[request_id] = (mono + duration, mono + duration + self.settings.cleanup_seconds)
            return self._view(db.execute('SELECT * FROM inference_leases WHERE id = ?', (request_id,)).fetchone())

    def release(self, request_id: str) -> dict[str, Any]:
        with self._mutex, self.store.transaction() as db:
            self._expire(db)
            row = db.execute('SELECT * FROM inference_leases WHERE id = ?', (request_id,)).fetchone()
            if row is None:
                now = self.wall()
                db.execute('INSERT INTO inference_leases VALUES(?,?,?,?,?,?,?,?,?)', (request_id, '', 'foreground', 0, 'canceled', now, now, now, now))
            elif row['state'] in {'pending', 'admitted'}:
                db.execute("UPDATE inference_leases SET state = ?, updated_at = ? WHERE id = ?", ('canceled' if row['state'] == 'pending' else 'released', self.wall(), request_id))
            self._deadlines.pop(request_id, None)
            return self._view(db.execute('SELECT * FROM inference_leases WHERE id = ?', (request_id,)).fetchone())


class AcquireRequest(BaseModel):
    model_config = ConfigDict(extra='forbid')
    request_id: uuid.UUID
    resource: str = Field(pattern='^[a-f0-9]{64}$')
    priority: Priority
    requested_seconds: float = Field(gt=0, le=3600, allow_inf_nan=False)


async def start() -> None:
    global _policy, _managed
    _managed = True
    if _policy is None:
        path = os.environ.get('TASK_DB_PATH', '').strip()
        if not path:
            raise RuntimeError('Inference admission requires the resolved task storage path')
        _policy = await asyncio.to_thread(lambda: AdmissionPolicy(TaskStore(path), Settings.environment()))


def stop() -> None:
    global _policy
    _policy = None


@router.post('')
async def acquire(body: AcquireRequest) -> dict[str, Any]:
    if _policy is None:
        raise HTTPException(503, 'Inference scheduling is unavailable')
    try:
        return await asyncio.to_thread(_policy.request, str(body.request_id), body.resource, body.priority, body.requested_seconds)
    except ValueError as exc:
        raise HTTPException(409, str(exc)) from None


@router.post('/{request_id}/release')
async def release(request_id: uuid.UUID) -> dict[str, Any]:
    if _policy is None:
        raise HTTPException(503, 'Inference scheduling is unavailable')
    return await asyncio.to_thread(_policy.release, str(request_id))


async def run(base: str, operation: Callable[[float], Awaitable[T]], requested_seconds: float,
              priority: Priority | None = None, research_budget: ResearchBudget | None = None) -> T:
    policy = _policy
    if policy is None:
        if _managed:
            raise AdmissionUnavailable('Inference scheduling is unavailable')
        return await operation(requested_seconds)
    request_id = str(uuid.uuid4())
    resource = endpoint_resource(base)
    selected = priority or priority_context.get()
    active: asyncio.Task[T] | None = None
    try:
        while True:
            started = time.monotonic()
            lease = await asyncio.to_thread(policy.request, request_id, resource, selected, requested_seconds, research_budget)
            if lease['state'] == 'admitted':
                remaining = lease['generation_seconds_remaining'] - (time.monotonic() - started)
                if remaining <= 0:
                    raise AdmissionUnavailable('The inference reservation expired before the request started')
                break
            if lease['state'] != 'pending':
                raise AdmissionUnavailable('The inference reservation is no longer active')
            await asyncio.sleep(lease['poll_seconds'])
        cutoff = time.monotonic() + remaining
        active = asyncio.create_task(operation(remaining))
        done, _ = await asyncio.wait({active}, timeout=remaining)
        if active not in done:
            active.cancel()
            raise TimeoutError('The inference request reached its total deadline')
        if time.monotonic() >= cutoff:
            raise TimeoutError('The inference result arrived after its deadline')
        return active.result()
    finally:
        if active is not None and not active.done():
            active.cancel()
            await asyncio.wait({active}, timeout=policy.settings.cleanup_seconds)
        if active is None or active.done():
            await asyncio.shield(asyncio.to_thread(policy.release, request_id))
        if active is not None:
            active.add_done_callback(lambda task: None if task.cancelled() else task.exception())
