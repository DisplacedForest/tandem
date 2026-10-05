import asyncio
import json
import os
import signal
import sqlite3
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Any

import httpx
import pytest
from fastapi import FastAPI

from routers import tasks
from routers.task_runtime import Dispatcher
from routers.task_store import MAX_JSON_BYTES, StepResult, TaskConflict, TaskStore


@pytest.fixture
def store(tmp_path: Path) -> TaskStore:
    return TaskStore(str(tmp_path / 'tasks.db'))


def create(store: TaskStore, key: str = 'first', worker: str = 'test') -> dict[str, Any]:
    return store.create(worker, {'goal': 'Read sources', 'origin': {'conversation_id': 'local-conversation'}}, key)


def test_create_is_atomic_and_concurrent_retries_are_identical(store: TaskStore) -> None:
    with ThreadPoolExecutor(max_workers=8) as pool:
        results = list(pool.map(lambda _: create(store), range(20)))
    assert len({task['id'] for task in results}) == 1
    assert len(store.events()) == 1
    assert len(store.list()) == 1
    assert TaskStore(store.path).get(results[0]['id'])['payload']['origin']['conversation_id'] == 'local-conversation'
    with pytest.raises(TaskConflict):
        store.create('test', {'goal': 'Different'}, 'first')
    with pytest.raises(TaskConflict):
        store.create('other', results[0]['payload'], 'first')


def test_atomic_checkpoint_event_rollback(store: TaskStore, monkeypatch: pytest.MonkeyPatch) -> None:
    task = create(store)
    claimed = store.claim(('test',))
    before = store.events()
    original = store._event

    def fail(*args: Any) -> int:
        original(*args)
        raise sqlite3.OperationalError('injected write failure')

    monkeypatch.setattr(store, '_event', fail)
    with pytest.raises(sqlite3.OperationalError):
        store.commit_step(task['id'], claimed['generation'], StepResult(checkpoint={'cursor': 1}))
    assert store.get(task['id'])['state'] == 'running'
    assert store.get(task['id'])['checkpoint'] == {}
    assert store.events() == before
    with pytest.raises(sqlite3.OperationalError):
        create(store, 'rolled-back')
    assert len(store.list()) == 1


@pytest.mark.parametrize('state', ['queued', 'blocked', 'needs_decision', 'completed', 'failed'])
def test_transitions_and_terminal_fences(store: TaskStore, state: str) -> None:
    task = create(store)
    claimed = store.claim(('test',))
    updated = store.commit_step(task['id'], claimed['generation'], StepResult(state=state, checkpoint={'cursor': 1}, decision={'prompt': 'Continue?'} if state == 'needs_decision' else None))
    assert updated['state'] == state
    assert updated['checkpoint'] == {'cursor': 1}
    with pytest.raises(TaskConflict):
        store.commit_step(task['id'], claimed['generation'], StepResult(state='completed'))
    if state != 'queued':
        assert store.claim(('test',)) is None
    if state in {'completed', 'failed'}:
        before = store.events()
        assert store.cancel(task['id'])['state'] == state
        assert store.events() == before
        with pytest.raises(TaskConflict):
            store.resume(task['id'])


def test_queue_fairness_and_single_active_claim(store: TaskStore) -> None:
    unknown = create(store, 'unknown', 'unconfigured')
    first = create(store)
    second = create(store, 'second')
    claimed = store.claim(('test',))
    assert claimed['id'] == first['id']
    assert store.claim(('test',)) is None
    store.commit_step(first['id'], claimed['generation'], StepResult(checkpoint={'cursor': 1}))
    assert store.claim(('test',))['id'] == second['id']
    assert store.get(unknown['id'])['state'] == 'queued'


def test_cancel_boundaries_retries_and_late_completion(store: TaskStore) -> None:
    queued = create(store)
    assert store.cancel(queued['id'])['state'] == 'canceled'
    assert store.claim(('test',)) is None
    task = create(store, 'running')
    claimed = store.claim(('test',))
    assert store.cancel(task['id'])['state'] == 'running'
    before = store.events()
    store.cancel(task['id'])
    assert store.events() == before
    canceled = store.commit_step(task['id'], claimed['generation'], StepResult(state='completed', checkpoint={'late': True}, result={'late': True}))
    assert canceled['state'] == 'canceled'
    assert canceled['checkpoint'] == {}
    assert canceled['result'] is None
    with pytest.raises(TaskConflict):
        store.commit_step(task['id'], claimed['generation'], StepResult(state='completed'))
    assert store.cancel(task['id']) == canceled


def test_decision_identity_and_reply_replay(store: TaskStore) -> None:
    task = create(store)
    claimed = store.claim(('test',))
    waiting = store.commit_step(task['id'], claimed['generation'], StepResult(state='needs_decision', checkpoint={'cursor': 2}, decision={'prompt': 'Choose', 'id': 'untrusted'}))
    decision_id = waiting['decision']['id']
    assert decision_id != 'untrusted'
    with pytest.raises(TaskConflict):
        store.respond(task['id'], 'wrong', 'reply', {'action': 'retry'})
    replied = store.respond(task['id'], decision_id, 'reply', {'action': 'retry'})
    before = store.events()
    assert store.respond(task['id'], decision_id, 'reply', {'action': 'retry'}) == replied
    assert store.events() == before
    with pytest.raises(TaskConflict):
        store.respond(task['id'], decision_id, 'reply', {'action': 'different'})
    resumed = store.claim(('test',))
    assert resumed['decision_reply'] == {'action': 'retry'}
    assert resumed['checkpoint'] == {'cursor': 2}
    waiting_again = store.commit_step(task['id'], resumed['generation'], StepResult(state='needs_decision', decision={'prompt': 'Choose again'}))
    assert waiting_again['decision']['id'] != decision_id
    assert store.respond(task['id'], decision_id, 'reply', {'action': 'retry'}) == waiting_again
    assert store.get(task['id'])['state'] == 'needs_decision'
    store.cancel(task['id'])
    with pytest.raises(TaskConflict):
        store.respond(task['id'], waiting_again['decision']['id'], 'new-reply', {})


def test_recovery_preserves_decision_reply_and_fences_claim(store: TaskStore) -> None:
    task = create(store)
    claim = store.claim(('test',))
    waiting = store.commit_step(task['id'], claim['generation'], StepResult(state='needs_decision', checkpoint={'cursor': 3}, decision={'prompt': 'Retry'}))
    store.respond(task['id'], waiting['decision']['id'], 'reply', {'action': 'retry'})
    stale = store.claim(('test',))
    assert store.recover() == 1
    assert store.recover() == 0
    resumed = store.claim(('test',))
    assert resumed['checkpoint'] == {'cursor': 3}
    assert resumed['decision_reply'] == {'action': 'retry'}
    with pytest.raises(TaskConflict):
        store.commit_step(task['id'], stale['generation'], StepResult(state='completed'))


@pytest.mark.parametrize('cancel', [False, True])
def test_sigkill_recovery_and_persisted_cancel(tmp_path: Path, cancel: bool) -> None:
    path = str(tmp_path / 'process.db')
    program = '''
import asyncio, json, sys
from routers.task_store import TaskStore, StepResult
from routers.task_runtime import Dispatcher
async def run():
    store = TaskStore(sys.argv[1])
    task = store.create('fake', {}, 'kill-test')
    store.create('unconfigured', {}, 'queued-survivor')
    async def step(task):
        if not task['checkpoint']:
            return StepResult(checkpoint={'cursor': 1, 'sources': ['https://example.test/source']})
        print(json.dumps(task), flush=True)
        await asyncio.Event().wait()
    dispatcher = Dispatcher(store)
    dispatcher.register('fake', step, 60)
    await dispatcher.start()
    await asyncio.Event().wait()
asyncio.run(run())
'''
    process = subprocess.Popen([sys.executable, '-u', '-c', program, path], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, cwd=Path(__file__).resolve().parents[1])
    try:
        import select
        assert select.select([process.stdout], [], [], 10)[0], 'child did not reach persisted checkpoint'
        task = json.loads(process.stdout.readline())
        if cancel:
            TaskStore(path).cancel(task['id'])
        os.kill(process.pid, signal.SIGKILL)
        process.wait(timeout=5)
        assert process.returncode == -signal.SIGKILL
        recovered = TaskStore(path)
        assert recovered.get(task['id'])['state'] == 'running'

        async def reopen() -> None:
            dispatcher = Dispatcher(recovered)
            await dispatcher.start()
            try:
                saved = recovered.get(task['id'])
                assert saved['state'] == ('canceled' if cancel else 'queued')
                assert saved['checkpoint']['cursor'] == 1
                assert saved['checkpoint']['sources'] == ['https://example.test/source']
                assert any(t['state'] == 'queued' and t['worker_type'] == 'unconfigured' for t in recovered.list())
                with pytest.raises(TaskConflict):
                    recovered.commit_step(task['id'], task['generation'], StepResult(state='completed'))
            finally:
                await dispatcher.stop()

        asyncio.run(reopen())
        assert len({e['id'] for e in recovered.events()}) == len(recovered.events())
    finally:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=5)
        process.stdout.close()
        process.stderr.close()


def test_event_log_is_append_only_and_bounds_are_enforced(store: TaskStore) -> None:
    task = create(store)
    with store.connect() as db:
        with pytest.raises(sqlite3.IntegrityError):
            db.execute("UPDATE task_events SET kind = 'changed'")
        with pytest.raises(sqlite3.IntegrityError):
            db.execute('DELETE FROM task_events')
    with pytest.raises(ValueError):
        store.create('test', {'huge': 'x' * MAX_JSON_BYTES}, 'huge')
    claim = store.claim(('test',))
    before = store.events()
    with pytest.raises(ValueError):
        store.commit_step(task['id'], claim['generation'], StepResult(data={'huge': 'x' * 16384}))
    assert store.get(task['id'])['state'] == 'running'
    assert store.events() == before
    with pytest.raises(TaskConflict):
        store.commit_step(task['id'], claim['generation'], StepResult(state='running'))


async def until(predicate: Any) -> None:
    async with asyncio.timeout(3):
        while not predicate():
            await asyncio.sleep(0.01)


def test_dispatcher_fake_worker_timeout_exception_and_lock(store: TaskStore) -> None:
    async def run() -> None:
        async def step(task: dict[str, Any]) -> StepResult:
            if task['payload'].get('error'):
                raise RuntimeError('private worker details')
            if task['payload'].get('timeout'):
                await asyncio.sleep(5)
            return StepResult(state='completed', result={'answer': 'ok'})

        dispatcher = Dispatcher(store, 0.01)
        dispatcher.register('test', step, 0.03)
        await dispatcher.start()
        competitor = Dispatcher(TaskStore(store.path))
        with pytest.raises(RuntimeError, match='active dispatcher'):
            await competitor.start()
        good = create(store)
        error = store.create('test', {'error': True}, 'error')
        timeout = store.create('test', {'timeout': True}, 'timeout')
        try:
            await until(lambda: store.get(timeout['id'])['state'] == 'failed')
            assert store.get(good['id'])['result'] == {'answer': 'ok'}
            assert store.get(error['id'])['state'] == 'failed'
            assert store.events(task_id=error['id'])[-1]['data'] == {'reason': 'worker_error'}
            assert store.events(task_id=timeout['id'])[-1]['data'] == {'reason': 'step_timeout'}
        finally:
            await dispatcher.stop()
        await competitor.start()
        await competitor.stop()

    asyncio.run(run())


def test_timeout_late_result_does_not_win_or_overlap(store: TaskStore) -> None:
    async def run() -> None:
        release = asyncio.Event()
        began = asyncio.Event()
        calls = []

        async def stubborn(task: dict[str, Any]) -> StepResult:
            calls.append(task['id'])
            began.set()
            while not release.is_set():
                try:
                    await release.wait()
                except asyncio.CancelledError:
                    continue
            return StepResult(state='completed', result={'late': True})

        dispatcher = Dispatcher(store, 0.01, 0.02)
        dispatcher.register('test', stubborn, 0.04)
        first, second = create(store), create(store, 'second')
        await dispatcher.start()
        competitor = Dispatcher(TaskStore(store.path))
        try:
            await began.wait()
            await until(lambda: dispatcher.failure is not None)
            assert store.get(first['id'])['state'] == 'failed'
            assert calls == [first['id']]
            assert store.get(second['id'])['state'] == 'queued'
            assert not await dispatcher.stop()
            with pytest.raises(RuntimeError, match='active dispatcher'):
                await competitor.start()
            release.set()
            await until(lambda: dispatcher._lock is None)
            await competitor.start()
            assert store.get(first['id'])['state'] == 'failed'
            assert store.get(first['id'])['result'] is None
        finally:
            release.set()
            await dispatcher.stop()
            await competitor.stop()

    asyncio.run(run())


def test_stop_recovers_running_checkpoint_and_cancel(store: TaskStore) -> None:
    async def run() -> None:
        began = asyncio.Event()

        async def step(task: dict[str, Any]) -> StepResult:
            began.set()
            await asyncio.Event().wait()
            return StepResult(state='completed')

        task = create(store)
        dispatcher = Dispatcher(store)
        dispatcher.register('test', step, 10)
        await dispatcher.start()
        await began.wait()
        store.cancel(task['id'])
        await dispatcher.stop()
        assert store.get(task['id'])['state'] == 'canceled'

    asyncio.run(run())


def test_sse_global_cursor_filter_and_insert_between_reads(store: TaskStore) -> None:
    class Connection:
        async def is_disconnected(self) -> bool:
            return False

    async def run() -> None:
        first, other = create(store), create(store, 'other')
        cursor = store.events(task_id=other['id'])[-1]['id']
        stream = tasks.event_stream(store, cursor, first['id'], Connection(), 0.001)
        pending = asyncio.create_task(anext(stream))
        await asyncio.sleep(0.02)
        claimed = store.claim(('test',))
        store.commit_step(first['id'], claimed['generation'], StepResult(event='source_found', data={'url': 'https://example.test'}))
        event = await asyncio.wait_for(pending, 1)
        event_id = int(event.splitlines()[0].split(': ')[1])
        assert event_id > cursor
        await stream.aclose()
        store.cancel(other['id'])
        resumed = tasks.event_stream(store, event_id, first['id'], Connection(), 0.001)
        next_event = await asyncio.wait_for(anext(resumed), 1)
        assert 'source_found' in next_event
        assert str(other['id']) not in next_event
        assert int(next_event.splitlines()[0].split(': ')[1]) > event_id
        await resumed.aclose()

    asyncio.run(run())


def test_rest_contract_and_unconfigured_behavior(store: TaskStore, monkeypatch: pytest.MonkeyPatch) -> None:
    async def run() -> None:
        dispatcher = Dispatcher(store)
        monkeypatch.setattr(tasks, '_runtime', dispatcher)
        app = FastAPI()
        app.include_router(tasks.router)
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url='http://test') as client:
            assert (await client.post('/tasks', json={'worker_type': 'unknown', 'payload': {}, 'idempotency_key': 'new'})).status_code == 503
            assert store.list() == []
            assert (await client.get('/tasks/missing')).status_code == 404
            dispatcher.register('test', lambda task: None, 1)
            body = {'worker_type': 'test', 'payload': {'goal': 'test'}, 'idempotency_key': 'rest'}
            response = await client.post('/tasks', json=body)
            assert response.status_code == 201
            task = response.json()
            assert (await client.post('/tasks', json=body)).json()['id'] == task['id']
            assert (await client.post('/tasks', json={**body, 'payload': {}})).status_code == 409
            assert (await client.get('/tasks')).json()['tasks'][0]['id'] == task['id']
            claim = store.claim(('test',))
            waiting = store.commit_step(task['id'], claim['generation'], StepResult(state='needs_decision', decision={'prompt': 'Retry?'}))
            reply = {'decision_id': waiting['decision']['id'], 'idempotency_key': 'response', 'reply': {'action': 'retry'}}
            assert (await client.post(f"/tasks/{task['id']}/decision", json=reply)).json()['state'] == 'queued'
            assert (await client.post(f"/tasks/{task['id']}/cancel")).json()['state'] == 'canceled'
            assert (await client.get('/tasks/events', headers={'Last-Event-ID': 'bad'})).status_code == 422
            assert (await client.get('/tasks/events', headers={'Last-Event-ID': '999999'})).status_code == 409
            assert (await client.get('/tasks/events', params={'task_id': 'missing'})).status_code == 404

    asyncio.run(run())


def test_data_root_and_explicit_path(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    import data_root
    from data_paths import STORE_PATHS
    assert STORE_PATHS['TASK_DB_PATH'] == 'tasks.db'
    monkeypatch.setenv('VERA_DATA_DIR', str(tmp_path / 'root'))
    monkeypatch.delenv('TASK_DB_PATH', raising=False)
    data_root.apply()
    assert os.environ['TASK_DB_PATH'] == str(tmp_path / 'root' / 'tasks.db')
    explicit = str(tmp_path / 'override.db')
    monkeypatch.setenv('TASK_DB_PATH', explicit)
    data_root.apply()
    assert os.environ['TASK_DB_PATH'] == explicit


def test_transient_commit_failure_retries_same_result(store: TaskStore, monkeypatch: pytest.MonkeyPatch) -> None:
    async def run() -> None:
        calls = []
        attempts = []
        original = store.commit_step

        def transient(task_id: str, generation: int, outcome: StepResult) -> dict[str, Any]:
            attempts.append(task_id)
            if len(attempts) == 1:
                raise sqlite3.OperationalError('database is locked')
            return original(task_id, generation, outcome)

        async def step(task: dict[str, Any]) -> StepResult:
            calls.append(task['id'])
            return StepResult(state='completed', checkpoint={'cursor': 1}, result={'answer': 'Saved'})

        monkeypatch.setattr(store, 'commit_step', transient)
        first, second = create(store), create(store, 'next')
        dispatcher = Dispatcher(store, 0.001)
        dispatcher.register('test', step, 1)
        await dispatcher.start()
        try:
            await until(lambda: store.get(second['id'])['state'] == 'completed')
            assert calls == [first['id'], second['id']]
            assert attempts == [first['id'], first['id'], second['id']]
            assert store.get(first['id'])['checkpoint'] == {'cursor': 1}
            assert len([e for e in store.events(task_id=first['id']) if e['state'] == 'completed']) == 1
        finally:
            await dispatcher.stop()

    asyncio.run(run())


def test_persistent_commit_failure_reports_unavailable_and_recovers(store: TaskStore, monkeypatch: pytest.MonkeyPatch) -> None:
    async def run() -> None:
        async def step(task: dict[str, Any]) -> StepResult:
            return StepResult(state='completed')

        def fail(*args: Any) -> None:
            raise sqlite3.OperationalError('database unavailable')

        monkeypatch.setattr(store, 'commit_step', fail)
        task = create(store)
        dispatcher = Dispatcher(store, 0.001)
        dispatcher.register('test', step, 1)
        monkeypatch.setattr(tasks, '_runtime', dispatcher)
        await dispatcher.start()
        await until(lambda: dispatcher.failure is not None)
        assert store.get(task['id'])['state'] == 'running'
        with pytest.raises(Exception) as exc:
            tasks.runtime()
        assert exc.value.status_code == 503
        await dispatcher.stop()
        assert store.get(task['id'])['state'] == 'queued'

    asyncio.run(run())


def test_shutdown_retains_ownership_until_cancel_suppressing_worker_exits(store: TaskStore) -> None:
    async def run() -> None:
        started, release, finished = asyncio.Event(), asyncio.Event(), asyncio.Event()

        async def step(task: dict[str, Any]) -> StepResult:
            started.set()
            while not release.is_set():
                try:
                    await release.wait()
                except asyncio.CancelledError:
                    continue
            finished.set()
            return StepResult(state='completed', result={'late': True})

        task = create(store)
        dispatcher = Dispatcher(store, cancellation_grace_seconds=0.02)
        dispatcher.register('test', step, 60)
        await dispatcher.start()
        await started.wait()
        assert not await asyncio.wait_for(dispatcher.stop(), 1)
        assert dispatcher.failure is not None
        assert dispatcher._active is not None
        assert store.get(task['id'])['state'] == 'running'
        competitor = Dispatcher(TaskStore(store.path))
        with pytest.raises(RuntimeError, match='active dispatcher'):
            await competitor.start()
        release.set()
        await asyncio.wait_for(finished.wait(), 1)
        await until(lambda: dispatcher._lock is None)
        assert store.get(task['id'])['state'] == 'queued'
        assert store.get(task['id'])['result'] is None
        await competitor.start()
        await competitor.stop()
        await dispatcher.stop()

    asyncio.run(run())


def test_list_cursor_does_not_skip_tied_timestamps(store: TaskStore, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr('routers.task_store.time.time', lambda: 1234.0)
    expected = {create(store, str(i))['id'] for i in range(6)}
    seen = []
    cursor = None
    while page := store.list(2, cursor):
        seen.extend(task['id'] for task in page)
        cursor = page[-1]['id']
    assert len(seen) == 6
    assert set(seen) == expected


def test_blocked_resume_and_waiting_restart(store: TaskStore) -> None:
    task = create(store)
    claim = store.claim(('test',))
    store.commit_step(task['id'], claim['generation'], StepResult(state='blocked', checkpoint={'reason': 'unconfigured'}))
    assert store.recover() == 0
    assert store.get(task['id'])['state'] == 'blocked'
    resumed = store.resume(task['id'])
    assert resumed['checkpoint'] == {'reason': 'unconfigured'}
    claim = store.claim(('test',))
    waiting = store.commit_step(task['id'], claim['generation'], StepResult(state='needs_decision', decision={'prompt': 'Continue?'}))
    assert store.recover() == 0
    assert store.get(task['id'])['decision'] == waiting['decision']


def test_sse_http_last_event_id_precedence_and_replay(store: TaskStore, monkeypatch: pytest.MonkeyPatch) -> None:
    async def run() -> None:
        task = create(store)
        cursor = store.events()[0]['id']
        claim = store.claim(('test',))
        store.commit_step(task['id'], claim['generation'], StepResult(state='completed'))
        original = tasks.event_stream

        async def finite(store: TaskStore, after: int, task_id: str | None, request: Any) -> Any:
            stream = original(store, after, task_id, request)
            for _ in range(2):
                yield await anext(stream)
            await stream.aclose()

        monkeypatch.setattr(tasks, 'event_stream', finite)
        monkeypatch.setattr(tasks, '_runtime', Dispatcher(store))
        app = FastAPI()
        app.include_router(tasks.router)
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url='http://test') as client:
            response = await client.get('/tasks/events?after=0', headers={'Last-Event-ID': str(cursor)})
            assert response.status_code == 200
            assert response.headers['content-type'].startswith('text/event-stream')
            ids = [int(line[4:]) for line in response.text.splitlines() if line.startswith('id: ')]
            assert ids == [event['id'] for event in store.events(after=cursor)]
            assert '"kind":"created"' not in response.text

    asyncio.run(run())


def test_invalid_worker_transition_fails_without_stranding_queue(store: TaskStore) -> None:
    async def run() -> None:
        async def invalid(task: dict[str, Any]) -> StepResult:
            return StepResult(state='running')
        task = create(store)
        dispatcher = Dispatcher(store, 0.001)
        dispatcher.register('test', invalid, 1)
        await dispatcher.start()
        try:
            await until(lambda: store.get(task['id'])['state'] == 'failed')
            assert dispatcher.failure is None
            assert store.events(task_id=task['id'])[-1]['data'] == {'reason': 'invalid_step_result'}
        finally:
            await dispatcher.stop()
    asyncio.run(run())


def test_worker_mutation_cannot_change_saved_checkpoint_on_error(store: TaskStore) -> None:
    async def run() -> None:
        async def mutate(task: dict[str, Any]) -> StepResult:
            task['checkpoint']['uncommitted'] = True
            task['generation'] += 10
            raise RuntimeError('failed before checkpoint')
        task = create(store)
        dispatcher = Dispatcher(store, 0.001)
        dispatcher.register('test', mutate, 1, ('read_sources',))
        assert dispatcher.workers['test'].tools == ('read_sources',)
        await dispatcher.start()
        try:
            await until(lambda: store.get(task['id'])['state'] == 'failed')
            assert store.get(task['id'])['checkpoint'] == {}
        finally:
            await dispatcher.stop()
    asyncio.run(run())


def test_worker_declaration_bounds(store: TaskStore) -> None:
    async def step(task: dict[str, Any]) -> StepResult:
        return StepResult()
    for timeout in (0, -1, float('nan'), float('inf')):
        with pytest.raises(ValueError):
            Dispatcher(store).register('test', step, timeout)
    for names in (['mutable'], ('duplicate', 'duplicate'), ('',), ('x' * 81,)):
        with pytest.raises(ValueError):
            Dispatcher(store).register('test', step, 1, names)


def test_lifespan_cleans_existing_services_when_task_shutdown_fails(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv('VERA_DATA_DIR', str(tmp_path / 'app-data'))
    import main
    calls = []

    async def home_start() -> None:
        calls.append('home-start')

    async def scheduler_start() -> None:
        calls.append('scheduler-start')

    async def task_start() -> None:
        calls.append('task-start')

    async def task_stop() -> None:
        calls.append('task-stop')
        raise RuntimeError('injected shutdown failure')

    async def scheduler_stop() -> None:
        calls.append('scheduler-stop')

    async def home_stop() -> None:
        calls.append('home-stop')

    monkeypatch.setattr(main.inference_admission, '_managed', False)
    monkeypatch.setattr(main.config_report, 'report', lambda *args, **kwargs: None)
    monkeypatch.setattr(main.identity_migrate, 'run', lambda: None)
    monkeypatch.setattr(main.vein_engine, 'load_block_modules', lambda: None)
    monkeypatch.setattr(main.home_events, 'start', home_start)
    monkeypatch.setattr(main.scheduler, 'start', scheduler_start)
    monkeypatch.setattr(main.tasks, 'start', task_start)
    monkeypatch.setattr(main.tasks, 'stop', task_stop)
    monkeypatch.setattr(main.scheduler, 'stop', scheduler_stop)
    monkeypatch.setattr(main.home_events, 'stop', home_stop)

    async def run() -> None:
        with pytest.raises(RuntimeError, match='injected shutdown failure'):
            async with main.lifespan(main.app):
                assert calls == ['home-start', 'scheduler-start', 'task-start']
        assert calls == ['home-start', 'scheduler-start', 'task-start', 'task-stop', 'scheduler-stop', 'home-stop']

    asyncio.run(run())
