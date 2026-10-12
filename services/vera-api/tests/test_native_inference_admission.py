import asyncio
import json
import os
import socket
import sys
import time
from pathlib import Path

import pytest
import uvicorn
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, StreamingResponse

from routers import inference_admission as admission, model_client
from routers.task_store import TaskStore

ROOT = Path(__file__).resolve().parents[3]
BINARY = ROOT / 'apps/vera-mac/.build/debug/Vera'
pytestmark = pytest.mark.skipif(os.environ.get('VERA_NATIVE_ADMISSION_TEST') != '1', reason='Run the build-dependent native-admission-test task')
RESOURCE_VECTORS = ['https://model.test/é/v1', 'https://model.test/%c3%a9/v1/', 'https://model.test/%7euser/%2f/v1', 'https://[::1]:443/v1/', 'http://MODEL.test:80/v1/', 'https://model.test/space here/v1']


async def fixture(tmp_path, monkeypatch, scenario, *, saturated=False, lose_grant=False, restart=False):
    assert sys.platform == 'darwin' and BINARY.exists(), 'The dedicated native admission task requires a built Mac app'
    settings = admission.Settings(background_seconds=0.8, foreground_seconds=0.25 if scenario in {'late', 'resistant', 'slow-release'} else 2, cleanup_seconds=0.05, poll_seconds=0.01)
    policy = admission.AdmissionPolicy(TaskStore(str(tmp_path / 'tasks.db')), settings)
    monkeypatch.setattr(admission, '_policy', policy)
    app = FastAPI()
    app.include_router(admission.router)
    begun, unblock, foreground_seen = asyncio.Event(), asyncio.Event(), asyncio.Event()
    order, requests, provider_headers, queue_measurements = [], [], [], []
    transport_released = asyncio.Event()
    lost = False
    restarted = False

    @app.middleware('http')
    async def record(request, call_next):
        nonlocal lost, restarted
        if request.url.path == '/inference/admission':
            body = await request.json()
            requests.append((body, dict(request.headers)))
            if scenario == 'outage':
                return JSONResponse({'error': 'synthetic outage'}, status_code=503)
            before = time.monotonic()
            response = await call_next(request)
            queue_measurements.append(time.monotonic() - before)
            if body['priority'] == 'foreground':
                foreground_seen.set()
            if restart and not restarted:
                restarted = True
                monkeypatch.setattr(admission, '_policy', admission.AdmissionPolicy(TaskStore(policy.store.path), settings))
            if lose_grant and not lost:
                lost = True
                return JSONResponse({'error': 'synthetic lost response'}, status_code=503)
            return response
        response = await call_next(request)
        if request.url.path.endswith('/release'):
            transport_released.set()
            if scenario == 'slow-release':
                await asyncio.sleep(0.4)
        return response

    @app.get('/fixture/released')
    async def wait_for_cleanup():
        await asyncio.wait_for(transport_released.wait(), 1)
        return {'released': True}

    @app.post('/v1/embeddings')
    async def embeddings(request: Request):
        provider_headers.append(dict(request.headers))
        return {'data': [{'embedding': [1, 0, 0]}]}

    @app.post('/v1/chat/completions')
    async def provider(request: Request):
        body = await request.json()
        provider_headers.append(dict(request.headers))
        label = body['messages'][0]['content']
        if label.startswith('Return only JSON:'):
            label = 'memory'
        order.append((label, time.monotonic()))
        if label == 'bg-0':
            begun.set()
            await unblock.wait()
        if scenario == 'cancel' and label == 'native-fixture':
            await asyncio.sleep(0.3)
        if not body.get('stream'):
            return {'choices': [{'message': {'content': '{"proposals":[]}' if label == 'memory' else label}, 'finish_reason': 'stop'}]}
        async def chunks():
            yield 'data: ' + json.dumps({'choices': [{'delta': {'content': 'early' if scenario == 'late' else 'native reply'}, 'finish_reason': None}]}) + '\n\n'
            if scenario == 'late':
                await asyncio.sleep(0.4)
                yield 'data: ' + json.dumps({'choices': [{'delta': {'content': 'late'}, 'finish_reason': None}]}) + '\n\n'
            yield 'data: ' + json.dumps({'choices': [{'delta': {}, 'finish_reason': 'stop'}]}) + '\n\n'
            yield 'data: [DONE]\n\n'
        return StreamingResponse(chunks(), media_type='text/event-stream')

    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.bind(('127.0.0.1', 0))
    base = f'http://127.0.0.1:{sock.getsockname()[1]}'
    server = uvicorn.Server(uvicorn.Config(app, log_level='error', lifespan='off'))
    serving = asyncio.create_task(server.serve(sockets=[sock]))
    background = []
    process = None
    try:
        async with asyncio.timeout(3):
            while not server.started:
                await asyncio.sleep(0.01)
        if saturated:
            monkeypatch.setattr(model_client, 'config', lambda _: {'base': base + '/v1', 'model': 'fixture', 'timeout': 5})
            monkeypatch.setattr(model_client, '_main_kwargs', lambda _: None)
            first = asyncio.create_task(model_client.complete_text([{'role': 'user', 'content': 'bg-0'}], priority='background'))
            background.append(first)
            await begun.wait()
            background.extend(asyncio.create_task(model_client.complete_text([{'role': 'user', 'content': f'bg-{i}'}], priority='background')) for i in range(1, 5))
        env = {key: value for key, value in os.environ.items() if not any(s in key for s in ('API_KEY', 'TOKEN', 'SECRET'))}
        env['VERA_ADMISSION_SELFTEST_CONFIG'] = json.dumps({'base': base, 'scenario': scenario, 'resource_urls': RESOURCE_VECTORS})
        process = await asyncio.create_subprocess_exec(str(BINARY), '--selftest', env=env, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
        if saturated:
            await asyncio.wait_for(foreground_seen.wait(), 5)
            released_at = time.monotonic()
            unblock.set()
        else:
            released_at = time.monotonic()
        stdout, stderr = await asyncio.wait_for(process.communicate(), 8)
        assert process.returncode == 0, stderr.decode()
        lines = [line for line in stdout.decode().splitlines() if line.startswith('ADMISSION_FIXTURE ')]
        assert len(lines) == 1, stdout.decode()
        result = json.loads(lines[0].split(' ', 1)[1])
        if background:
            await asyncio.gather(*background)
        assert all('authorization' not in headers for _, headers in requests)
        assert all('synthetic-fixture-key' not in json.dumps(body) for body, _ in requests)
        native_headers = [headers for headers in provider_headers if headers.get('authorization')]
        assert all(headers['authorization'] == 'Bearer synthetic-fixture-key' for headers in native_headers)
        assert result['resource'] == admission.endpoint_resource(base + '/v1')
        return result, order, requests, released_at, policy, queue_measurements
    finally:
        unblock.set()
        for task in background:
            if not task.done():
                task.cancel()
        await asyncio.gather(*background, return_exceptions=True)
        if process is not None and process.returncode is None:
            process.kill()
            await process.wait()
        server.should_exit = True
        await asyncio.wait_for(serving, 3)
        sock.close()


def test_native_transport_foreground_outranks_saturated_background(tmp_path, monkeypatch):
    result, order, requests, released_at, _, _ = asyncio.run(fixture(tmp_path, monkeypatch, 'stream', saturated=True))
    assert result['outcome'] == 'completed'
    assert [name for name, _ in order][:2] == ['bg-0', 'native-fixture']
    assert order[1][1] - released_at < 0.4
    assert result['frames'][-1] == 'native reply'


@pytest.mark.parametrize('scenario', ['stream', 'nonstream'])
def test_native_idle_has_no_queue_sleep_and_reports_actual_overhead(tmp_path, monkeypatch, scenario):
    result, order, requests, _, _, measurements = asyncio.run(fixture(tmp_path, monkeypatch, scenario))
    assert result['outcome'] == 'completed'
    assert len(requests) == 1
    assert len(order) == 1
    assert result['elapsed_seconds'] < 1
    assert max(measurements) < 0.2
    print(json.dumps({'scenario': scenario, 'native_elapsed_seconds': result['elapsed_seconds'], 'admission_handler_seconds': measurements[0]}))


def test_native_lost_grant_retries_same_identity_across_api_restart(tmp_path, monkeypatch):
    result, order, requests, _, _, _ = asyncio.run(fixture(tmp_path, monkeypatch, 'stream', lose_grant=True, restart=True))
    assert result['outcome'] == 'completed'
    assert len(order) == 1
    assert len(requests) == 2
    assert requests[0][0]['request_id'] == requests[1][0]['request_id']


def test_native_cancellation_releases_actual_transport_lease(tmp_path, monkeypatch):
    result, _, requests, _, policy, _ = asyncio.run(fixture(tmp_path, monkeypatch, 'cancel'))
    assert result['outcome'] == 'canceled'
    assert len(requests) == 1
    with policy.store.connect() as db:
        state = db.execute('SELECT state FROM inference_leases WHERE id = ?', (requests[0][0]['request_id'],)).fetchone()[0]
    assert state == 'released'


def test_native_total_deadline_discards_late_stream_frames(tmp_path, monkeypatch):
    result, _, _, _, _, _ = asyncio.run(fixture(tmp_path, monkeypatch, 'late'))
    assert result['outcome'] == 'failed'
    assert result['frames'] and all(frame == 'early' for frame in result['frames'])
    assert result['elapsed_seconds'] < 0.6


@pytest.mark.parametrize('scenario,priority', [('memory-background', 'background'), ('memory-foreground', 'foreground')])
def test_native_memory_generation_joins_correct_priority(tmp_path, monkeypatch, scenario, priority):
    result, _, requests, _, _, _ = asyncio.run(fixture(tmp_path, monkeypatch, scenario))
    assert result['outcome'] == 'completed'
    assert len(requests) == 1 and requests[0][0]['priority'] == priority


@pytest.mark.parametrize('scenario', ['uncoordinated', 'embedding'])
def test_default_native_constructor_and_embeddings_bypass_admission(tmp_path, monkeypatch, scenario):
    result, _, requests, _, _, _ = asyncio.run(fixture(tmp_path, monkeypatch, scenario))
    assert result['outcome'] == 'completed'
    assert not requests


def test_native_resistant_operation_returns_at_cutoff_without_late_result(tmp_path, monkeypatch):
    result, _, _, _, _, _ = asyncio.run(fixture(tmp_path, monkeypatch, 'resistant'))
    assert result['outcome'] == 'failed'
    assert result['returned_seconds'] < 0.4
    assert result['frames'] == []


def test_native_and_api_resource_fingerprints_match_shared_url_vectors(tmp_path, monkeypatch):
    result, _, requests, _, _, _ = asyncio.run(fixture(tmp_path, monkeypatch, 'resources'))
    assert result['resource_vectors'] == {url: admission.endpoint_resource(url) for url in RESOURCE_VECTORS}
    assert not requests


def test_native_timely_generation_survives_slow_release_response(tmp_path, monkeypatch):
    result, _, _, _, _, _ = asyncio.run(fixture(tmp_path, monkeypatch, 'slow-release'))
    assert result['outcome'] == 'completed'
    assert result['frames'][-1] == 'native reply'


def test_native_latency_samples(tmp_path, monkeypatch):
    import statistics
    samples = {}
    for label, scenario, saturated in [('direct_idle', 'uncoordinated', False), ('coordinated_idle', 'stream', False), ('saturated', 'stream', True)]:
        rows = []
        for index in range(3):
            case = tmp_path / f'{label}-{index}'
            case.mkdir()
            result, order, _, _, _, _ = asyncio.run(fixture(case, monkeypatch, scenario, saturated=saturated))
            assert result['outcome'] == 'completed'
            if saturated:
                assert [name for name, _ in order][:2] == ['bg-0', 'native-fixture']
            rows.append({'first_content_seconds': result['first_content_seconds'], 'total_seconds': result['elapsed_seconds'], **result['measurements']})
        first = sorted(row['first_content_seconds'] for row in rows)
        samples[label] = {'raw': rows, 'first_content_p50': statistics.median(first), 'first_content_p95': first[-1]}
    print('NATIVE_ADMISSION_LATENCY ' + json.dumps(samples, sort_keys=True))


def test_native_cancel_before_deadline_race_starts_no_operation(tmp_path, monkeypatch):
    result, order, requests, _, _, _ = asyncio.run(fixture(tmp_path, monkeypatch, 'cancel-before-start'))
    assert result['outcome'] == 'canceled'
    assert result['measurements']['not_started_cleanup'] == 1
    assert result['measurements']['cancellation_observed'] == 1
    assert 'unexpected_operation' not in result['measurements']
    assert not order and not requests


def test_native_cancel_after_grant_releases_without_starting_provider(tmp_path, monkeypatch):
    result, order, requests, _, policy, _ = asyncio.run(fixture(tmp_path, monkeypatch, 'cancel-after-grant'))
    assert result['outcome'] == 'canceled'
    assert len(requests) == 1 and not order
    with policy.store.connect() as db:
        assert db.execute('SELECT state FROM inference_leases').fetchone()[0] == 'released'


def test_native_admission_outage_never_calls_provider(tmp_path, monkeypatch):
    result, order, requests, _, _, _ = asyncio.run(fixture(tmp_path, monkeypatch, 'outage'))
    assert result['outcome'] == 'failed'
    assert len(requests) == 2 and requests[0][0]['request_id'] == requests[1][0]['request_id']
    assert not order
