import asyncio
from types import SimpleNamespace

import pytest
from fastapi import HTTPException
from pydantic import ValidationError

from routers import native_generation as relay
from routers.task_store import TaskStore


@pytest.fixture
def native_task(tmp_path, monkeypatch):
    store = TaskStore(str(tmp_path / 'tasks.db'))
    binding = {'id': 'native-binding', 'admission_base': 'https://provider.test/v1', 'enrollment_digest': 'a' * 64}
    store.create('research', {'query': 'Fictional moons', 'native_binding': binding}, 'request')
    task = store.claim(('research',))
    monkeypatch.setattr(relay.tasks, 'runtime', lambda: SimpleNamespace(store=store))
    relay._presence.clear()
    relay._pending.clear()
    yield store, task, relay.NativeBinding(**binding)
    relay._presence.clear()
    relay._pending.clear()


async def direct_admission(base, operation, seconds, priority):
    assert base == 'https://provider.test/v1' and priority == 'background'
    return await operation(min(seconds, 0.5))


@pytest.mark.asyncio
async def test_absent_app_never_acquires_permit(native_task):
    _, task, _ = native_task

    async def forbidden(*args, **kwargs):
        raise AssertionError('No permit may be acquired while the app is absent')

    with pytest.raises(relay.NativeExecutorUnavailable):
        await relay.caller(task, 'plan', 'initial', forbidden)([{'role': 'user', 'content': 'Question'}])
    assert not relay._pending


@pytest.mark.asyncio
async def test_bound_generation_roundtrip_and_repair_identity(native_task):
    _, task, binding = native_task
    assert (await relay.ready(task['id'], binding)).status_code == 204
    complete = relay.caller(task, 'plan', 'initial', direct_admission)
    for index in range(2):
        running = asyncio.create_task(complete([{'role': 'user', 'content': f'Question {index}'}]))
        while task['id'] not in relay._pending:
            await asyncio.sleep(0)
        wire = await relay.ready(task['id'], binding)
        assert wire['attempt'] == f'initial-{index}' and 0 < wire['deadline_seconds'] <= 0.5
        body = relay.GenerationResponse(job_id=wire['id'], binding_id=binding.id, generation=task['generation'],
            messages_digest=wire['messages_digest'], response='Bounded answer')
        await relay.result(task['id'], body)
        assert await running == 'Bounded answer'
    assert not relay._pending


@pytest.mark.asyncio
async def test_cancel_rejects_late_response_and_releases_pending(native_task):
    store, task, binding = native_task
    await relay.ready(task['id'], binding)
    running = asyncio.create_task(relay.caller(task, 'plan', 'initial', direct_admission)(
        [{'role': 'user', 'content': 'Question'}]))
    while task['id'] not in relay._pending:
        await asyncio.sleep(0)
    wire = await relay.ready(task['id'], binding)
    store.cancel(task['id'])
    with pytest.raises(HTTPException) as error:
        await relay.result(task['id'], relay.GenerationResponse(job_id=wire['id'], binding_id=binding.id,
            generation=task['generation'], messages_digest=wire['messages_digest'], response='Late answer'))
    assert error.value.status_code == 409
    with pytest.raises(asyncio.CancelledError):
        await running
    assert not relay._pending


@pytest.mark.asyncio
async def test_disconnect_is_recoverable_absence(native_task):
    _, task, binding = native_task
    await relay.ready(task['id'], binding)

    async def short_admission(base, operation, seconds, priority):
        return await operation(0.01)

    with pytest.raises(relay.NativeExecutorUnavailable):
        await relay.caller(task, 'plan', 'initial', short_admission)([{'role': 'user', 'content': 'Question'}])
    assert not relay._pending


@pytest.mark.asyncio
async def test_changed_binding_cannot_signal_readiness(native_task):
    _, task, binding = native_task
    with pytest.raises(HTTPException):
        await relay.ready(task['id'], binding.model_copy(update={'admission_base': 'https://other.test/v1'}))
    assert not relay._presence


@pytest.mark.asyncio
async def test_oversize_input_is_rejected_before_admission(native_task):
    _, task, binding = native_task
    await relay.ready(task['id'], binding)
    with pytest.raises(relay.NativeGenerationFailed, match='input_limit'):
        await relay.caller(task, 'plan', 'initial', direct_admission)([{'role': 'user', 'content': '\U0001f600' * 17000}])
    assert not relay._pending


@pytest.mark.asyncio
async def test_generation_failures_are_fixed_categories(native_task):
    _, task, binding = native_task
    await relay.ready(task['id'], binding)
    for failure in ('provider_auth', 'provider_quota', 'request_limit'):
        running = asyncio.create_task(relay.caller(task, 'plan', 'initial', direct_admission)(
            [{'role': 'user', 'content': 'Question'}]))
        while task['id'] not in relay._pending:
            await asyncio.sleep(0)
        wire = await relay.ready(task['id'], binding)
        await relay.result(task['id'], relay.GenerationResponse(job_id=wire['id'], binding_id=binding.id,
            generation=task['generation'], messages_digest=wire['messages_digest'], failure=failure))
        with pytest.raises(relay.NativeGenerationFailed, match=failure):
            await running


def test_no_arbitrary_failure_text_or_extra_options():
    body = dict(job_id='job', binding_id='binding', generation=1, messages_digest='a' * 64)
    with pytest.raises(ValidationError):
        relay.GenerationResponse(**body, failure='secret-sentinel-provider-body')
    with pytest.raises(ValidationError):
        relay.GenerationResponse(**body, response='ok', headers={'Authorization': 'secret-sentinel'})
    with pytest.raises(ValidationError):
        relay.NativeBinding(id='x', admission_base='https://secret@provider.test/v1', enrollment_digest='a' * 64)


def test_message_digest_is_ordered_utf8_length_framed():
    messages = [{'content': 'Snow \u2603 / \U0001f600', 'role': 'user'}, {'role': 'assistant', 'content': '\u0001'}]
    assert relay.messages_digest(messages) == 'b14976f7840083cd7ca915ca02b21f937629b21a6c0a5c5075f5b8c4331b39aa'


@pytest.mark.asyncio
@pytest.mark.parametrize('remove', [True, False])
async def test_ready_rechecks_job_after_suspended_snapshot(native_task, monkeypatch, remove):
    import time
    _, task, binding = native_task
    pending = relay.PendingGeneration(wire={'generation': task['generation']}, deadline=time.monotonic() + 2,
                                      outcome=asyncio.get_running_loop().create_future())
    relay._pending[task['id']] = pending
    original = relay.tasks.call
    calls = 0

    async def delayed(method, *args):
        nonlocal calls
        value = await original(method, *args)
        calls += 1
        if calls == 2:
            await asyncio.sleep(0)
            if remove:
                relay._pending.pop(task['id'])
            else:
                pending.deadline = time.monotonic() - 1
        return value

    monkeypatch.setattr(relay.tasks, 'call', delayed)
    assert (await relay.ready(task['id'], binding)).status_code == 204


@pytest.mark.asyncio
async def test_actual_admission_timeout_remains_recoverable(native_task, monkeypatch):
    from routers import inference_admission as admission
    store, task, binding = native_task
    monkeypatch.setattr(admission, '_policy', admission.AdmissionPolicy(store, admission.Settings(
        background_seconds=0.04, cleanup_seconds=0.01, poll_seconds=0.005)))
    await relay.ready(task['id'], binding)
    with pytest.raises(relay.NativeExecutorUnavailable):
        await relay.caller(task, 'plan', 'initial')([{'role': 'user', 'content': 'Question'}])
    await asyncio.sleep(0.01)
    assert not relay._pending
