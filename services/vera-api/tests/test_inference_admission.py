import asyncio
import hashlib
import json
import os
import subprocess
import sys
import time
import uuid
from pathlib import Path

import httpx
import pytest
from fastapi import FastAPI

from routers import inference_admission as admission
from routers import model_client, tasks
from routers.task_runtime import Dispatcher
from routers.task_store import StepResult, TaskStore


RESOURCE = admission.endpoint_resource('http://model.test/v1')


class Clock:
    def __init__(self):
        self.wall = 1000.0
        self.mono = 0.0

    def advance(self, seconds):
        self.wall += seconds
        self.mono += seconds


@pytest.fixture
def policy(tmp_path):
    return admission.AdmissionPolicy(TaskStore(str(tmp_path / 'tasks.db')),
                                     admission.Settings(background_seconds=0.15, foreground_seconds=0.3, cleanup_seconds=0.03, pending_seconds=0.5, poll_seconds=0.002))


def request(policy, name, priority='background', seconds=60):
    return policy.request(name, RESOURCE, priority, seconds)


def test_foreground_precedes_every_queued_background(policy):
    assert request(policy, 'active')['state'] == 'admitted'
    for n in range(5):
        assert request(policy, f'queued-{n}')['state'] == 'pending'
    assert request(policy, 'foreground', 'foreground')['state'] == 'pending'
    policy.release('active')
    for n in range(5):
        assert request(policy, f'queued-{n}')['state'] == 'pending'
    assert request(policy, 'foreground', 'foreground')['state'] == 'admitted'
    assert request(policy, 'queued-0')['state'] == 'pending'
    policy.release('foreground')
    assert request(policy, 'queued-0')['state'] == 'admitted'
    assert request(policy, 'queued-1')['state'] == 'pending'


def test_slot_configuration_and_resource_isolation(tmp_path):
    policy = admission.AdmissionPolicy(TaskStore(str(tmp_path / 'slots.db')), admission.Settings(background_slots=2))
    assert request(policy, 'one')['state'] == 'admitted'
    assert request(policy, 'two')['state'] == 'admitted'
    assert request(policy, 'three')['state'] == 'pending'
    assert policy.request('separate', 'f' * 64, 'background', 5)['state'] == 'admitted'
    assert request(policy, 'foreground', 'foreground')['state'] == 'pending'
    policy.release('one')
    assert request(policy, 'three')['state'] == 'pending'
    policy.release('two')
    assert request(policy, 'foreground', 'foreground')['state'] == 'admitted'


def test_duplicate_acquire_never_extends_active_deadline_and_cancel_race(policy):
    first = request(policy, 'stable')
    time.sleep(0.01)
    second = request(policy, 'stable')
    assert second['generation_seconds_remaining'] < first['generation_seconds_remaining']
    with pytest.raises(ValueError):
        request(policy, 'stable', 'foreground')
    assert policy.release('stable')['state'] == 'released'
    assert request(policy, 'stable')['state'] == 'released'
    assert policy.release('cancel-before-arrival')['state'] == 'canceled'
    assert request(policy, 'cancel-before-arrival')['state'] == 'canceled'
    assert policy.release('cancel-before-arrival')['state'] == 'canceled'


def test_restart_preserves_live_grant_and_pending_foreground(tmp_path):
    clock = Clock()
    path = str(tmp_path / 'restart.db')
    settings = admission.Settings(background_seconds=2, cleanup_seconds=1)
    first = admission.AdmissionPolicy(TaskStore(path), settings, lambda: clock.wall, lambda: clock.mono)
    request(first, 'running')
    request(first, 'queued')
    request(first, 'voice', 'foreground')
    clock.advance(1)
    second = admission.AdmissionPolicy(TaskStore(path), settings, lambda: clock.wall, lambda: clock.mono)
    assert request(second, 'voice', 'foreground')['state'] == 'pending'
    assert request(second, 'queued')['state'] == 'pending'
    assert request(second, 'running')['generation_seconds_remaining'] == 1
    clock.advance(1.1)
    assert request(second, 'voice', 'foreground')['state'] == 'pending'
    clock.advance(1)
    assert request(second, 'voice', 'foreground')['state'] == 'admitted'
    assert request(second, 'queued')['state'] == 'pending'
    assert request(second, 'running')['state'] == 'expired'


def test_expiry_monotonic_in_process_and_recovery_clock_clamp(tmp_path):
    clock = Clock()
    path = str(tmp_path / 'clock.db')
    settings = admission.Settings(background_seconds=2, cleanup_seconds=1)
    policy = admission.AdmissionPolicy(TaskStore(path), settings, lambda: clock.wall, lambda: clock.mono)
    request(policy, 'running')
    clock.wall += 10000
    assert request(policy, 'running')['generation_seconds_remaining'] == 2
    clock.wall -= 20000
    recovered = admission.AdmissionPolicy(TaskStore(path), settings, lambda: clock.wall, lambda: clock.mono)
    assert request(recovered, 'running')['generation_seconds_remaining'] == 2
    clock.advance(3.1)
    assert request(recovered, 'running')['state'] == 'expired'


def test_pending_expiry_is_safe_and_background_stays_fifo(tmp_path):
    clock = Clock()
    settings = admission.Settings(background_seconds=2, cleanup_seconds=1, pending_seconds=0.2, poll_seconds=0.01)
    policy = admission.AdmissionPolicy(TaskStore(str(tmp_path / 'pending.db')), settings, lambda: clock.wall, lambda: clock.mono)
    request(policy, 'active')
    request(policy, 'abandoned', 'foreground')
    clock.advance(0.3)
    policy.release('active')
    assert request(policy, 'new')['state'] == 'admitted'
    assert request(policy, 'abandoned', 'foreground')['state'] == 'expired'


def test_resource_fingerprint_has_no_credentials_and_supports_groups(tmp_path):
    plain = admission.endpoint_resource('https://model.test/v1')
    assert admission.endpoint_resource('HTTPS://user:secret@MODEL.test:443/v1/?key=private#secret') == plain
    assert plain == hashlib.sha256(b'https://model.test/v1').hexdigest()
    other = admission.endpoint_resource('https://alias.test/v1')
    policy = admission.AdmissionPolicy(TaskStore(str(tmp_path / 'groups.db')), admission.Settings(groups={plain: 'shared', other: 'shared'}))
    assert policy.request('first', plain, 'background', 1)['state'] == 'admitted'
    assert policy.request('second', other, 'foreground', 1)['state'] == 'pending'
    with policy.store.connect() as db:
        serialized = json.dumps([dict(row) for row in db.execute('SELECT * FROM inference_leases')])
    assert 'secret' not in serialized and 'https:' not in serialized


@pytest.mark.parametrize('kwargs', [{'background_slots': 0}, {'background_slots': 33}, {'background_seconds': float('nan')}, {'foreground_seconds': float('inf')}, {'cleanup_seconds': 0}, {'pending_seconds': -1}, {'groups': []}])
def test_config_validation(kwargs):
    with pytest.raises(ValueError):
        admission.Settings(**kwargs)


def test_actual_model_client_priority_saturation_and_idle(policy, monkeypatch):
    async def run():
        monkeypatch.setattr(admission, '_policy', policy)
        monkeypatch.setattr(model_client, 'config', lambda _: {'base': 'http://model.test/v1', 'model': 'fake', 'timeout': 5})
        monkeypatch.setattr(model_client, '_main_kwargs', lambda _: None)
        entered = []
        started = asyncio.Event()
        release = asyncio.Event()

        async def slow(url, body, timeout):
            label = body['messages'][0]['content']
            entered.append((label, time.monotonic(), timeout))
            if label == 'bg-0':
                started.set()
                await release.wait()
            return {'choices': [{'message': {'content': label}}]}

        monkeypatch.setattr(model_client, '_post', slow)
        async def call(label, priority='background'):
            return await model_client.complete_text([{'role': 'user', 'content': label}], priority=priority)
        first = asyncio.create_task(call('bg-0'))
        await started.wait()
        queued = [asyncio.create_task(call(f'bg-{i}')) for i in range(1, 6)]
        foreground = asyncio.create_task(call('foreground', 'foreground'))
        await asyncio.sleep(0.02)
        before = time.monotonic()
        release.set()
        assert await foreground == 'foreground'
        assert time.monotonic() - before < policy.settings.background_seconds + policy.settings.cleanup_seconds + 0.3
        await asyncio.gather(first, *queued)
        assert [name for name, _, _ in entered][:2] == ['bg-0', 'foreground']
        assert all(timeout <= policy.settings.background_seconds for name, _, timeout in entered if name.startswith('bg'))
        idle = await call('idle', 'foreground')
        assert idle == 'idle'
        with policy.store.connect() as db:
            rows = db.execute("SELECT * FROM inference_leases WHERE state = 'released'").fetchall()
        assert len(rows) == 8

    asyncio.run(run())


def test_cancellation_releases_pending_and_active(policy, monkeypatch):
    async def run():
        monkeypatch.setattr(admission, '_policy', policy)
        began = asyncio.Event()
        stopped = asyncio.Event()
        async def wait(seconds):
            began.set()
            try:
                await asyncio.Event().wait()
            finally:
                stopped.set()
        active = asyncio.create_task(admission.run('http://model.test/v1', wait, 2, 'background'))
        await began.wait()
        waiting = asyncio.create_task(admission.run('http://model.test/v1', wait, 2, 'foreground'))
        await asyncio.sleep(0.01)
        waiting.cancel()
        with pytest.raises(asyncio.CancelledError):
            await waiting
        active.cancel()
        with pytest.raises(asyncio.CancelledError):
            await active
        assert stopped.is_set()
        assert request(policy, 'next')['state'] == 'admitted'
    asyncio.run(run())


def test_deadline_discards_stubborn_result_and_lease_expires(policy, monkeypatch):
    async def run():
        monkeypatch.setattr(admission, '_policy', policy)
        release = asyncio.Event()
        async def stubborn(seconds):
            while not release.is_set():
                try:
                    await release.wait()
                except asyncio.CancelledError:
                    continue
            return 'late'
        started = time.monotonic()
        try:
            with pytest.raises(TimeoutError):
                await admission.run('http://model.test/v1', stubborn, 2, 'background')
            assert time.monotonic() - started < 0.5
            await asyncio.sleep(0.01)
            assert request(policy, 'foreground', 'foreground')['state'] == 'admitted'
        finally:
            release.set()
            await asyncio.sleep(0.01)
    asyncio.run(run())


def test_worker_context_automatic_and_foreground_router_independent_of_worker_failure(policy, monkeypatch):
    async def run():
        seen = []
        async def worker(task):
            seen.append(admission.priority_context.get())
            return StepResult(state='completed')
        store = policy.store
        store.create('fake', {}, 'worker')
        dispatcher = Dispatcher(store, 0.001)
        dispatcher.register('fake', worker, 1)
        token = admission.priority_context.set('foreground')
        await dispatcher.start()
        admission.priority_context.reset(token)
        async with asyncio.timeout(1):
            while not seen:
                await asyncio.sleep(0.001)
        assert seen == ['background']
        await dispatcher.stop()
        dispatcher.failure = 'unavailable worker'
        monkeypatch.setattr(tasks, '_runtime', dispatcher)
        monkeypatch.setattr(admission, '_policy', policy)
        app = FastAPI()
        app.include_router(admission.router)
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url='http://test') as client:
            key = str(uuid.uuid4())
            body = {'request_id': key, 'resource': RESOURCE, 'priority': 'foreground', 'requested_seconds': 1}
            response = await client.post('/inference/admission', json=body)
            assert response.status_code == 200 and response.json()['state'] == 'admitted'
            assert (await client.post(f'/inference/admission/{key}/release')).json()['state'] == 'released'
    asyncio.run(run())


def test_managed_outage_never_bypasses_admission(monkeypatch):
    monkeypatch.setattr(admission, '_managed', True)
    monkeypatch.setattr(admission, '_policy', None)
    calls = []
    async def operation(seconds):
        calls.append(seconds)
        return 'bypassed'
    with pytest.raises(admission.AdmissionUnavailable):
        asyncio.run(admission.run('http://model.test/v1', operation, 1))
    assert calls == []


def test_unicode_and_encoded_endpoint_identity_match():
    assert admission.endpoint_resource('https://model.test/é/v1') == admission.endpoint_resource('https://model.test/%c3%a9/v1/')
    assert admission.endpoint_resource('https://model.test/%7euser/v1') == admission.endpoint_resource('https://model.test/~user/v1')
    assert admission.endpoint_resource('https://model.test/a%2fb/v1') != admission.endpoint_resource('https://model.test/a/b/v1')


def test_interactive_http_generation_keeps_legacy_budget_while_worker_is_bounded(tmp_path, monkeypatch):
    from aiohttp import web
    async def run():
        app = web.Application()
        async def provider(request):
            await request.json()
            await asyncio.sleep(0.08)
            return web.json_response({'choices': [{'message': {'content': 'done'}}]})
        app.router.add_post('/v1/chat/completions', provider)
        runner = web.AppRunner(app)
        await runner.setup()
        site = web.TCPSite(runner, '127.0.0.1', 0)
        await site.start()
        host, port = runner.addresses[0][:2]
        store = TaskStore(str(tmp_path / 'worker-http.db'))
        policy = admission.AdmissionPolicy(store, admission.Settings(background_seconds=0.03, foreground_seconds=600, cleanup_seconds=0.02, poll_seconds=0.002))
        monkeypatch.setattr(admission, '_policy', policy)
        monkeypatch.setattr(model_client, 'config', lambda _: {'base': f'http://{host}:{port}/v1', 'model': 'fake', 'timeout': 300})
        monkeypatch.setattr(model_client, '_main_kwargs', lambda _: None)
        try:
            assert await model_client.complete_text([{'role': 'user', 'content': 'legacy'}]) == 'done'
            assert await model_client.complete_text([{'role': 'user', 'content': 'interactive'}], priority='foreground') == 'done'
            with store.connect() as db:
                rows = db.execute('SELECT priority, requested_seconds FROM inference_leases').fetchall()
            assert [(row['priority'], row['requested_seconds']) for row in rows] == [('foreground', 300), ('foreground', 300)]
            async def worker(task):
                try:
                    await model_client.complete_text([{'role': 'user', 'content': 'background'}])
                except TimeoutError:
                    return StepResult(state='failed', event='failed', data={'reason': 'bounded_generation'})
                return StepResult(state='completed')
            task = store.create('test', {}, 'background-http')
            dispatcher = Dispatcher(store, 0.002)
            dispatcher.register('test', worker, 1)
            await dispatcher.start()
            try:
                async with asyncio.timeout(1):
                    while store.get(task['id'])['state'] not in {'failed', 'completed'}:
                        await asyncio.sleep(0.01)
                assert store.get(task['id'])['state'] == 'failed'
                assert store.events(task_id=task['id'])[-1]['data'] == {'reason': 'bounded_generation'}
            finally:
                await dispatcher.stop()
        finally:
            await runner.cleanup()
    asyncio.run(run())


def test_sigkill_process_recovery_preserves_lease_and_foreground_order(tmp_path):
    script = """
import json
import sys
from routers.inference_admission import AdmissionPolicy, Settings
from routers.task_store import TaskStore
policy = AdmissionPolicy(TaskStore(sys.argv[1]), Settings(background_seconds=1.2, cleanup_seconds=0.1, pending_seconds=5))
for line in sys.stdin:
    command = json.loads(line)
    result = policy.release(command['id']) if command.get('release') else policy.request(command['id'], 'a' * 64, command.get('priority', 'background'), 60)
    print(json.dumps(result), flush=True)
"""
    path = str(tmp_path / 'process-restart.db')
    def start():
        return subprocess.Popen([sys.executable, '-u', '-c', script, path], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=os.environ.copy())
    def call(process, **command):
        process.stdin.write(json.dumps(command) + '\n')
        process.stdin.flush()
        return json.loads(process.stdout.readline())
    first = start()
    second = None
    try:
        assert call(first, id='running')['state'] == 'admitted'
        assert call(first, id='background')['state'] == 'pending'
        assert call(first, id='foreground', priority='foreground')['state'] == 'pending'
        first.kill()
        assert first.wait(timeout=5) < 0
        second = start()
        assert call(second, id='background')['state'] == 'pending'
        assert call(second, id='foreground', priority='foreground')['state'] == 'pending'
        recovered = call(second, id='running')
        assert recovered['state'] == 'admitted'
        assert 0 < recovered['generation_seconds_remaining'] < 1.2
        deadline = time.monotonic() + 3
        while call(second, id='foreground', priority='foreground')['state'] == 'pending':
            assert time.monotonic() < deadline
            time.sleep(0.02)
        assert call(second, id='running')['state'] == 'expired'
        assert call(second, id='background')['state'] == 'pending'
        assert call(second, id='foreground', release=True)['state'] == 'released'
        assert call(second, id='background')['state'] == 'admitted'
    finally:
        for process in (first, second):
            if process is not None:
                if process.poll() is None:
                    process.kill()
                process.communicate(timeout=5)
