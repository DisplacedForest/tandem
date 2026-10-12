import asyncio
import json
import os
import socket
import subprocess
import sqlite3
from pathlib import Path
from types import SimpleNamespace

import pytest
import uvicorn
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse

from routers import inference_admission as admission, native_generation as relay, research, task_research, tasks
from routers.task_runtime import Dispatcher, StepResult
from routers.task_store import TaskStore

ROOT = Path(__file__).resolve().parents[3]
BINARY = ROOT / 'apps/vera-mac/.build/debug/Vera'
pytestmark = pytest.mark.skipif(os.environ.get('VERA_NATIVE_TASK_TEST') != '1', reason='Run the build-dependent native-task-test task')


async def fixture(tmp_path, monkeypatch, scenario):
    store = TaskStore(str(tmp_path / 'tasks.db'))
    engine = Dispatcher(store, poll_seconds=0.01)
    async def waiting_step(task):
        return StepResult(state='blocked', checkpoint={'phase': 'gather', 'sources': []})

    engine.register('research', waiting_step if scenario == 'multiple' else task_research.step,
                    180 if scenario == 'live' else 5, task_research.TOOLS)
    monkeypatch.setattr(tasks, '_runtime', engine)
    monkeypatch.setitem(tasks._validators, 'research', task_research.validate_payload)
    monkeypatch.setattr(admission, '_policy', admission.AdmissionPolicy(store, admission.Settings(
        background_seconds=20 if scenario == 'live' else (0.7 if scenario == 'crash' else 3), cleanup_seconds=0.05, poll_seconds=0.01)))
    monkeypatch.setenv("STRUCTURED_REPAIR_ATTEMPTS", "1")
    relay._presence.clear()
    relay._pending.clear()
    monkeypatch.setattr(research, 'PLAN_SYS', 'Plan one search for the fictional question. Reply only with JSON containing a subquestions array of strings.')
    monkeypatch.setattr(research, 'voiced', lambda _: 'Write a report using only the fictional sources. Cite [n].')
    chat, provider_started, release = asyncio.Event(), asyncio.Event(), asyncio.Event()
    provider_calls, api_bodies, acknowledgments, foreground_calls = [], [], [], []
    lost = False
    lost_result = False
    lost_decision = False
    streams, decisions = [], []
    original_stream = tasks.event_stream

    async def event_stream(store, after, task_id, request, poll_seconds=0.25):
        async for event in original_stream(store, after, task_id, request, poll_seconds):
            yield event
            if scenario in {'reconnect', 'offline-completion'} and len(streams) == 1:
                return

    monkeypatch.setattr(tasks, 'event_stream', event_stream)

    async def search(_):
        await asyncio.wait_for(chat.wait(), 6)
        await asyncio.sleep(2.4 if scenario == 'reconnect' else 0.4)
        return SimpleNamespace(results=[SimpleNamespace(url='https://fictional.test/luma', title='Fictional moon guide',
                                                       content='The fictional moon Luma is blue.')])

    monkeypatch.setattr(research, 'web_search', search)
    app = FastAPI()
    app.include_router(tasks.router)
    app.include_router(relay.router)
    app.include_router(admission.router)

    @app.middleware('http')
    async def capture(request, call_next):
        nonlocal lost, lost_result, lost_decision
        if request.url.path == '/tasks/events':
            streams.append(request.query_params.get('after'))
        if request.url.path.endswith('/decision'):
            decisions.append(await request.json())
        if request.url.path.startswith('/tasks') and request.method == 'POST':
            body = await request.body()
            api_bodies.append(body.decode())
            assert 'authorization' not in request.headers
        if request.url.path.endswith('/native/result') and scenario == 'lost-result' and not lost_result:
            lost_result = True
            return JSONResponse({'error': 'synthetic lost result'}, status_code=503)
        response = await call_next(request)
        if request.url.path.endswith('/decision') and scenario == 'retry-lost-ack' and not lost_decision:
            lost_decision = True
            return JSONResponse({'error': 'synthetic lost decision acknowledgment'}, status_code=503)
        if request.url.path == '/tasks' and scenario == 'lost-ack' and not lost:
            lost = True
            return JSONResponse({'error': 'synthetic lost acknowledgment'}, status_code=503)
        return response

    @app.post('/fixture/chat')
    async def chatted():
        acknowledgments.append(store.list()[0]['state'])
        chat.set()
        return {'ok': True}

    @app.get('/fixture/provider-started')
    async def wait_for_provider():
        await asyncio.wait_for(provider_started.wait(), 5)
        return {'ready': True}

    @app.post('/v1/chat/completions')
    async def provider(request: Request):
        body = await request.json()
        assert request.headers.get('authorization') == 'Bearer synthetic-fixture-key'
        if body.get('tools'):
            foreground_calls.append(body)
            last = body['messages'][-1]
            if last['role'] == 'tool':
                message, finish = {'content': 'Research has started. You can keep chatting.'}, 'stop'
            elif 'Can you still respond' in last['content']:
                message, finish = {'content': "I'm still here while research runs."}, 'stop'
            else:
                message = {'content': '', 'tool_calls': [{'id': 'synthetic-native-tool', 'type': 'function',
                    'function': {'name': 'create_background_task', 'arguments': json.dumps({
                        'worker_type': 'research', 'objective': 'What color is the fictional moon Luma?',
                        'deliverables': ['A cited answer']})}}]}
                finish = 'tool_calls'
            return {'choices': [{'message': message, 'finish_reason': finish}]}
        assert body['max_tokens'] == 1024 and not body.get('tools') and not body.get('stream')
        assert not any(key in body for key in ('n', 'best_of', 'functions', 'function_call'))
        provider_calls.append(body)
        provider_started.set()
        if scenario in {'auth', 'quota', 'provider-error'}:
            status = {'auth': 401, 'quota': 429, 'provider-error': 500}[scenario]
            return JSONResponse({'error': {'message': 'secret-sentinel-provider-body'}}, status_code=status)
        if len(provider_calls) == 1 and scenario in {'crash', 'two-apps', 'cancel'}:
            await release.wait()
        planning = body['messages'][-1]['content'] == 'What color is the fictional moon Luma?'
        content = json.dumps({'subquestions': ['What color is Luma?']}) if planning else 'The fictional moon Luma is blue [1].'
        if scenario in {'retry', 'retry-lost-ack'} and not planning and len(provider_calls) == 2:
            content = 'The fictional moon Luma is blue [99].'
        return {'choices': [{'message': {'content': content}, 'finish_reason': 'length' if scenario == 'partial' else 'stop'}]}

    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.bind(('127.0.0.1', 0))
    base = f'http://127.0.0.1:{sock.getsockname()[1]}'
    server = uvicorn.Server(uvicorn.Config(app, log_level='error', lifespan='off'))
    serving = asyncio.create_task(server.serve(sockets=[sock]))
    processes = []
    database = tmp_path / 'native.sqlite'

    async def launch(mode):
        env = {key: value for key, value in os.environ.items()
               if not any(text in key for text in ('API_KEY', 'TOKEN', 'SECRET', 'VERA_ADMISSION_SELFTEST'))}
        env['VERA_TASK_SELFTEST_CONFIG'] = json.dumps({'base': base, 'database': database.as_uri(), 'mode': mode, 'nativeLead': scenario == 'native-lead', 'live': scenario == 'live',
            'retry': scenario in {'retry', 'retry-lost-ack'}, 'cursorAhead': scenario == 'cursor-ahead'})
        process = await asyncio.create_subprocess_exec(str(BINARY), '--selftest', env=env,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
        processes.append(process)
        return process

    try:
        await engine.start()
        async with asyncio.timeout(4):
            while not server.started:
                await asyncio.sleep(0.01)
        first = await launch('multiple' if scenario == 'multiple' else 'cancel' if scenario == 'cancel' else 'create')
        if scenario == 'multiple':
            stdout, stderr = await asyncio.wait_for(first.communicate(), 12)
            assert first.returncode == 0, (stdout.decode(), stderr.decode())
            assert len(store.list()) == 8 and len(streams) == 1 and not provider_calls
            assert sum(task['state'] == 'canceled' for task in store.list()) == 1
            with sqlite3.connect(database) as db:
                assert db.execute('SELECT COUNT(*) FROM native_task_projections').fetchone()[0] == 8
            (tmp_path / 'native-evidence.json').write_text(stdout.decode())
            print('TASK_CARD_EVIDENCE ' + stdout.decode().strip())
            return
        if scenario == 'crash':
            await asyncio.wait_for(provider_started.wait(), 6)
            first.kill()
            await first.wait()
            await asyncio.sleep(0.9)
            second = await launch('recover')
            stdout, stderr = await asyncio.wait_for(second.communicate(), 12)
            assert second.returncode == 0, (stdout.decode(), stderr.decode())
            assert len(provider_calls) == 1
            assert store.list()[0]['state'] == 'needs_decision'
        elif scenario == 'two-apps':
            await asyncio.wait_for(provider_started.wait(), 6)
            second = await launch('recover')
            await asyncio.sleep(0.25)
            assert len(provider_calls) == 1
            release.set()
            stdout, stderr = await asyncio.wait_for(first.communicate(), 150 if scenario == 'live' else 12)
            assert first.returncode == 0, (stdout.decode(), stderr.decode())
            other, errors = await asyncio.wait_for(second.communicate(), 12)
            assert second.returncode == 0, (other.decode(), errors.decode())
            assert len(provider_calls) == 2
        else:
            stdout, stderr = await asyncio.wait_for(first.communicate(), 150 if scenario == 'live' else 12)
            assert first.returncode == 0, (stdout.decode(), stderr.decode())
            assert len(provider_calls) == (0 if scenario == 'live' else 3 if scenario in {'retry', 'retry-lost-ack'} else 1 if scenario in {'cancel', 'auth', 'quota', 'provider-error', 'partial'} else 2)
        rows = [json.loads(line.split(' ', 1)[1]) for line in stdout.decode().splitlines() if line.startswith('TASK_FIXTURE ')]
        if scenario not in {'crash', 'cancel', 'auth', 'quota', 'provider-error', 'partial'}:
            assert store.list()[0]['state'] == 'completed'
            assert acknowledgments and all(state != 'completed' for state in acknowledgments)
            assert any(row['event'] == 'ack' for row in rows)
            assert any(row['event'] == 'chat' for row in rows)
            if scenario == 'live':
                assert '[1]' in store.list()[0]['result']['report']
            else:
                assert store.list()[0]['result']['report'] == 'The fictional moon Luma is blue [1].'
        if scenario in {'auth', 'quota', 'provider-error', 'partial'}:
            assert store.list()[0]['state'] == 'needs_decision'
            assert 'secret-sentinel-provider-body' not in stdout.decode()
        if scenario == 'cancel':
            assert store.list()[0]['state'] == 'canceled'
        if scenario == 'native-lead':
            assert len(foreground_calls) == 3
            assert all(row['first_content_seconds'] > 0 for row in rows if row['event'] in {'ack', 'chat'})
        assert len(store.list()) == 1
        assert any(row['event'] == 'cards' and row['cards'] == 1 and row['original_conversation'] for row in rows)
        if scenario in {'retry', 'retry-lost-ack'}:
            assert decisions and len({reply['idempotency_key'] for reply in decisions}) == 1
            assert all(reply['reply'] == {'action': 'retry'} for reply in decisions)
        if scenario == 'reconnect':
            assert len(streams) >= 2
        if scenario == 'offline-completion':
            assert len(streams) == 1
        if scenario == 'cursor-ahead':
            assert streams[0] == '100000' and '0' in streams[1:]
        assert all('synthetic-fixture-key' not in body and 'secret-sentinel-provider-body' not in body for body in api_bodies)
        with sqlite3.connect(database) as db:
            reserved = db.execute('SELECT COUNT(*) FROM native_task_generations').fetchone()[0]
            completed_generations = db.execute("SELECT COUNT(*) FROM native_task_generations WHERE state = 'completed'").fetchone()[0]
            assert 1 <= reserved <= 4 if scenario == 'live' else reserved == len(provider_calls)
            blocks = [json.loads(row[0]) for row in db.execute('SELECT display_blocks_json FROM messages WHERE display_blocks_json IS NOT NULL')]
            artifacts = [block for message in blocks for block in message if block['type'] == 'artifact']
            assert len(artifacts) == (1 if store.list()[0]['state'] == 'completed' else 0)
            for table in ('native_task_outbox', 'native_task_generations', 'native_task_projections', 'native_task_retries'):
                saved = str(db.execute(f'SELECT * FROM {table}').fetchall())
                assert 'synthetic-fixture-key' not in saved and 'secret-sentinel-provider-body' not in saved
        evidence = {'scenario': scenario, 'synthetic_provider_requests': len(provider_calls), 'foreground_requests': len(foreground_calls),
            'state': store.list()[0]['state'], 'reserved_requests': reserved, 'completed_generations': completed_generations, 'event_connections': len(streams), 'timings': [row for row in rows if row['event'] in {'ack', 'chat'}]}
        (tmp_path / 'native-evidence.json').write_text(json.dumps(evidence))
        print('TASK_EVIDENCE ' + json.dumps(evidence))
        return rows
    finally:
        release.set()
        chat.set()
        for process in processes:
            if process.returncode is None:
                process.kill()
                await process.wait()
        await engine.stop()
        server.should_exit = True
        await asyncio.wait_for(serving, 4)
        sock.close()


@pytest.mark.parametrize('scenario', ['complete', 'native-lead', 'lost-ack', 'lost-result', 'crash', 'two-apps', 'cancel', 'auth', 'quota', 'provider-error', 'partial', 'offline-completion', 'reconnect', 'cursor-ahead', 'retry', 'retry-lost-ack', 'multiple'])
def test_native_typed_handoff_actual_api(tmp_path, monkeypatch, scenario):
    asyncio.run(fixture(tmp_path, monkeypatch, scenario))


def test_native_card_persistence_fixtures():
    result = subprocess.run([str(BINARY), '--selftest'], env={**os.environ, 'VERA_TASK_SELFTEST_CONFIG': 'cards-unit'},
                            capture_output=True, text=True, timeout=15)
    assert result.returncode == 0, (result.stdout, result.stderr)
    assert 'NATIVE TASK DISPLAY FIXTURE OK' in result.stdout


def test_native_handoff_persistence_fixtures():
    result = subprocess.run([str(BINARY), '--selftest'], env={**os.environ, 'VERA_TASK_SELFTEST_CONFIG': 'unit'},
                            capture_output=True, text=True, timeout=10)
    assert result.returncode == 0, (result.stdout, result.stderr)
    assert 'NATIVE TASK FIXTURE OK' in result.stdout


@pytest.mark.skipif(os.environ.get('VERA_NATIVE_TASK_LIVE') != '1', reason='Requires explicit live background verification authorization')
def test_native_typed_handoff_live(tmp_path, monkeypatch):
    asyncio.run(fixture(tmp_path, monkeypatch, 'live'))


@pytest.mark.asyncio
async def test_native_session_second_input_during_blocked_http_tool(tmp_path):
    app = FastAPI()
    release = asyncio.Event()
    calls = []
    held = asyncio.Event()

    @app.get('/hold')
    async def hold():
        held.set()
        await asyncio.wait_for(release.wait(), 8)
        return {'ready': True}

    @app.get('/release')
    async def unblock():
        release.set()
        return {'ok': True}

    @app.post('/v1/chat/completions')
    async def completion(request: Request):
        body = await request.json()
        calls.append(body)
        question = next(message['content'] for message in reversed(body['messages']) if message['role'] == 'user')
        if question == 'slow question':
            message = {'role': 'assistant', 'content': '', 'tool_calls': [
                {'id': 'held-call', 'type': 'function', 'function': {'name': 'hold', 'arguments': '{}'}}]}
        else:
            await asyncio.wait_for(held.wait(), 4)
            message = {'role': 'assistant', 'content': 'The fridge answer is ready.'}
        return {'choices': [{'message': message, 'finish_reason': 'tool_calls' if 'tool_calls' in message else 'stop'}]}

    sock = socket.socket()
    sock.bind(('127.0.0.1', 0))
    sock.listen(128)
    port = sock.getsockname()[1]
    server = uvicorn.Server(uvicorn.Config(app, log_level='error'))
    serving = asyncio.create_task(server.serve(sockets=[sock]))
    process = None
    try:
        while not server.started:
            await asyncio.sleep(0.01)
        env = dict(os.environ, VERA_SESSION_HTTP_FIXTURE=f'http://127.0.0.1:{port}',
                   VERA_CONFIG_DIR=str(tmp_path / 'config'))
        process = await asyncio.create_subprocess_exec(str(BINARY), '--selftest', env=env,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        stdout, stderr = await asyncio.wait_for(process.communicate(), 12)
        assert process.returncode == 0, (stdout.decode(), stderr.decode())
        evidence = json.loads(next(line.split(' ', 1)[1] for line in stdout.decode().splitlines()
                                   if line.startswith('SESSION_HTTP_FIXTURE ')))
        assert evidence['messages'] == 4 and evidence['first_stopped'] and evidence['second_completed']
        assert evidence['accepted_seconds'] < 1 and evidence['second_answer_seconds'] < 3
        assert len(calls) == 2
        (tmp_path / 'session-evidence.json').write_text(json.dumps(evidence, indent=2))
    finally:
        release.set()
        if process is not None and process.returncode is None:
            process.kill()
            await process.wait()
        server.should_exit = True
        await serving
        sock.close()


@pytest.mark.asyncio
@pytest.mark.parametrize('second_already_open', [False, True])
async def test_native_session_process_restart_does_not_repeat_effect(tmp_path, second_already_open):
    app = FastAPI()
    effect = asyncio.Event()
    release = asyncio.Event()
    effects, questions = [], []

    @app.get('/effect')
    async def mutate():
        effects.append('saved')
        effect.set()
        await asyncio.wait_for(release.wait(), 12)
        return {'saved': True}

    @app.post('/v1/chat/completions')
    async def completion(request: Request):
        body = await request.json()
        question = next(message['content'] for message in reversed(body['messages']) if message['role'] == 'user')
        questions.append(question)
        if question == 'slow question':
            message = {'role': 'assistant', 'content': '', 'tool_calls': [
                {'id': 'effect-call', 'type': 'function', 'function': {'name': 'hold', 'arguments': '{}'}}]}
        else:
            message = {'role': 'assistant', 'content': 'The pending answer is ready.'}
        return {'choices': [{'message': message, 'finish_reason': 'tool_calls' if 'tool_calls' in message else 'stop'}]}

    sock = socket.socket()
    sock.bind(('127.0.0.1', 0))
    sock.listen(128)
    port = sock.getsockname()[1]
    server = uvicorn.Server(uvicorn.Config(app, log_level='error'))
    serving = asyncio.create_task(server.serve(sockets=[sock]))
    owner = survivor = None

    async def launch(mode):
        config = {'base': f'http://127.0.0.1:{port}', 'database': (tmp_path / 'sessions.sqlite').as_uri(), 'mode': mode}
        env = dict(os.environ, VERA_SESSION_RESTART_FIXTURE=json.dumps(config), VERA_CONFIG_DIR=str(tmp_path / 'config'))
        return await asyncio.create_subprocess_exec(str(BINARY), '--selftest', env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    try:
        while not server.started:
            await asyncio.sleep(0.01)
        owner = await launch('owner')
        assert b'SESSION_OWNER_READY' in await asyncio.wait_for(owner.stdout.readline(), 5)
        await asyncio.wait_for(effect.wait(), 5)
        if second_already_open:
            survivor = await launch('recover')
            await asyncio.sleep(0.15)
        owner.kill()
        await owner.wait()
        if survivor is None:
            survivor = await launch('recover')
        stdout, stderr = await asyncio.wait_for(survivor.communicate(), 8)
        assert survivor.returncode == 0, (stdout.decode(), stderr.decode())
        assert b'SESSION_RESTART_OK' in stdout
        assert effects == ['saved'] and questions == ['slow question', 'pending question']
        with sqlite3.connect(tmp_path / 'sessions.sqlite') as db:
            assert db.execute('SELECT COUNT(*) FROM messages').fetchone()[0] == 4
    finally:
        release.set()
        for process in (owner, survivor):
            if process is not None and process.returncode is None:
                process.kill()
                await process.wait()
        server.should_exit = True
        await serving
        sock.close()
