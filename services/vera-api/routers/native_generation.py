import asyncio
import hashlib
import json
import time
import uuid
from dataclasses import dataclass
from typing import Annotated, Any, Awaitable, Callable
from urllib.parse import urlsplit

from fastapi import APIRouter, HTTPException, Response
from pydantic import BaseModel, ConfigDict, Field, StringConstraints, field_validator, model_validator

from . import tasks

router = APIRouter(prefix='/tasks', tags=['tasks'])


class NativeExecutorUnavailable(Exception):
    pass


class NativeGenerationFailed(Exception):
    def __init__(self, reason: str):
        self.reason = reason
        super().__init__(reason)


class NativeBinding(BaseModel):
    model_config = ConfigDict(extra='forbid', strict=True)

    id: Annotated[str, StringConstraints(min_length=1, max_length=80)]
    admission_base: Annotated[str, StringConstraints(min_length=1, max_length=2048)]
    enrollment_digest: Annotated[str, StringConstraints(pattern=r'^[a-f0-9]{64}$')]

    @field_validator('admission_base')
    @classmethod
    def validate_base(cls, value: str) -> str:
        parts = urlsplit(value)
        if parts.scheme not in {'http', 'https'} or not parts.hostname or parts.username or parts.password or parts.query or parts.fragment:
            raise ValueError('A credential-free provider resource is required')
        return value


FAILURES = frozenset({'provider_unavailable', 'provider_auth', 'provider_quota', 'provider_response',
                      'canceled', 'request_timeout', 'profile_changed', 'credential_unavailable',
                      'request_conflict', 'previous_request_uncertain', 'request_limit', 'input_limit'})


class GenerationResponse(BaseModel):
    model_config = ConfigDict(extra='forbid', strict=True)

    job_id: str = Field(min_length=1, max_length=80)
    binding_id: str = Field(min_length=1, max_length=80)
    generation: int = Field(ge=1)
    messages_digest: str = Field(pattern=r'^[a-f0-9]{64}$')
    response: str | None = Field(default=None, max_length=262144)
    failure: str | None = None

    @model_validator(mode='after')
    def validate_result(self) -> 'GenerationResponse':
        if (self.response is None) == (self.failure is None):
            raise ValueError('Exactly one generation outcome is required')
        if self.failure is not None and self.failure not in FAILURES:
            raise ValueError('Unknown generation failure')
        if self.response is not None and len(self.response.encode('utf-8')) > 262144:
            raise ValueError('Generation output exceeds its limit')
        return self


@dataclass
class PendingGeneration:
    wire: dict[str, Any]
    deadline: float
    outcome: asyncio.Future[GenerationResponse]


_presence: dict[str, tuple[dict[str, str], float]] = {}
_pending: dict[str, PendingGeneration] = {}


def messages_digest(messages: list[dict[str, str]]) -> str:
    digest = hashlib.sha256()
    for message in messages:
        for field in ('role', 'content'):
            encoded = message[field].encode('utf-8')
            digest.update(str(len(encoded)).encode('ascii') + b':' + encoded)
    return digest.hexdigest()


def _binding(task: dict[str, Any], body: NativeBinding) -> None:
    if task['worker_type'] != 'research' or task['payload'].get('native_binding') != body.model_dump():
        raise HTTPException(409, 'Native task binding does not match')
    if task['cancel_requested'] or task['state'] in {'completed', 'failed', 'canceled', 'needs_decision'}:
        raise HTTPException(409, 'This task cannot request native generation')


@router.post('/{task_id}/native/ready')
async def ready(task_id: str, body: NativeBinding) -> Any:
    store = tasks.runtime().store
    task = await tasks.call(store.get, task_id)
    _binding(task, body)
    now = time.monotonic()
    for key, (_, expiry) in list(_presence.items()):
        if expiry <= now:
            _presence.pop(key, None)
    if len(_presence) >= 200 and task_id not in _presence:
        raise HTTPException(503, 'Native generation capacity is full')
    _presence[task_id] = (body.model_dump(), now + 3)
    if task['state'] == 'blocked':
        if task['checkpoint'].get('native_unavailable') != body.id:
            raise HTTPException(409, 'This task is blocked for another reason')
        await tasks.call(store.resume, task_id, task['generation'], {'native_unavailable': body.id})
    pending = _pending.get(task_id)
    if pending is None or pending.deadline <= now:
        return Response(status_code=204)
    current = await tasks.call(store.get, task_id)
    if current['cancel_requested'] or current['state'] != 'running' or current['generation'] != pending.wire['generation']:
        raise HTTPException(409, 'This generation is no longer active')
    remaining = pending.deadline - time.monotonic()
    if _pending.get(task_id) is not pending or remaining <= 0 or pending.outcome.done():
        return Response(status_code=204)
    return {**pending.wire, 'deadline_seconds': remaining}


@router.post('/{task_id}/native/result', status_code=204)
async def result(task_id: str, body: GenerationResponse) -> Response:
    task = await tasks.call(tasks.runtime().store.get, task_id)
    pending = _pending.get(task_id)
    if (pending is None or pending.deadline <= time.monotonic() or task['cancel_requested']
            or task['state'] != 'running' or task['generation'] != body.generation
            or pending.wire['id'] != body.job_id or pending.wire['binding_id'] != body.binding_id
            or pending.wire['generation'] != body.generation
            or pending.wire['messages_digest'] != body.messages_digest):
        raise HTTPException(409, 'This generation is no longer active')
    if pending.outcome.done():
        if pending.outcome.result() != body:
            raise HTTPException(409, 'This generation already has a different result')
    else:
        pending.outcome.set_result(body)
    return Response(status_code=204)


def caller(task: dict[str, Any], phase: str, attempt: str,
           admission: Callable[..., Awaitable[str]] | None = None) -> Callable[..., Awaitable[str]]:
    binding = NativeBinding.model_validate(task['payload']['native_binding'])
    slot = 0

    async def complete(messages: list[dict[str, str]], **options: Any) -> str:
        nonlocal slot
        ordinal = slot
        slot += 1
        if ordinal > 3:
            raise NativeGenerationFailed('request_limit')
        if (not 1 <= len(messages) <= 8 or any(set(message) != {'role', 'content'}
                or message['role'] not in {'system', 'user', 'assistant'}
                or not isinstance(message['content'], str) for message in messages)):
            raise NativeGenerationFailed('provider_response')
        encoded = json.dumps(messages, ensure_ascii=False, separators=(',', ':')).encode('utf-8')
        if len(encoded) > 65536:
            raise NativeGenerationFailed('input_limit')
        presence = _presence.get(task['id'])
        if presence is None or presence[0] != binding.model_dump() or presence[1] <= time.monotonic():
            raise NativeExecutorUnavailable()
        run = admission
        if run is None:
            from .inference_admission import run

        async def operation(seconds: float) -> str:
            presence = _presence.get(task['id'])
            if presence is None or presence[1] <= time.monotonic():
                raise NativeExecutorUnavailable()
            pending = PendingGeneration(
                wire={'id': str(uuid.uuid4()), 'task_id': task['id'], 'binding_id': binding.id,
                      'enrollment_digest': binding.enrollment_digest, 'admission_base': binding.admission_base,
                      'phase': phase, 'attempt': f'{attempt}-{ordinal}', 'messages': messages,
                      'messages_digest': messages_digest(messages), 'generation': task['generation']},
                deadline=time.monotonic() + min(seconds, 90), outcome=asyncio.get_running_loop().create_future())
            _pending[task['id']] = pending
            try:
                while time.monotonic() < pending.deadline:
                    current = await asyncio.to_thread(tasks.runtime().store.get, task['id'])
                    if current['cancel_requested'] or current['state'] != 'running' or current['generation'] != task['generation']:
                        raise asyncio.CancelledError()
                    if pending.outcome.done():
                        response = pending.outcome.result()
                        if response.failure:
                            raise NativeGenerationFailed(response.failure)
                        return response.response or ''
                    await asyncio.sleep(0.05)
                raise NativeExecutorUnavailable()
            finally:
                if _pending.get(task['id']) is pending:
                    _pending.pop(task['id'], None)
                if not pending.outcome.done():
                    pending.outcome.cancel()

        try:
            return await run(binding.admission_base, operation, 90, priority='background')
        except TimeoutError:
            raise NativeExecutorUnavailable() from None
        except RuntimeError as error:
            from .inference_admission import AdmissionUnavailable
            if isinstance(error, AdmissionUnavailable):
                raise NativeExecutorUnavailable() from None
            raise

    return complete
