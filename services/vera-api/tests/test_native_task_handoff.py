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


@pytest.mark.asyncio
@pytest.mark.parametrize('scenario,expected', [
    ('headers', 'completed'), ('body', 'read_idle_timeout'), ('overall', 'overall_timeout'),
    ('setup', 'connect_send_timeout'), ('short-overall', 'overall_timeout'), ('cancel', 'canceled'),
    ('auth', 'provider_auth'), ('quota', 'provider_quota'), ('error', 'provider_unavailable'),
])
async def test_native_provider_transport_deadlines_and_sanitized_diagnostics(scenario, expected):
    handlers = set()
    uploaded = asyncio.Event()
    async def connection(reader, writer):
        current = asyncio.current_task()
        handlers.add(current)
        try:
            if scenario in {'setup', 'short-overall'}:
                await asyncio.sleep(2)
                return
            header = await reader.readuntil(b'\r\n\r\n')
            length = next(int(line.split(b':', 1)[1]) for line in header.split(b'\r\n') if line.lower().startswith(b'content-length:'))
            await reader.readexactly(length)
            uploaded.set()
            if scenario in {'headers', 'cancel'}:
                await asyncio.sleep(0.4)
            status = {'auth': 401, 'quota': 429, 'error': 503}.get(scenario, 200)
            body = json.dumps({'choices': [{'message': {'content': 'Synthetic complete answer'}, 'finish_reason': 'stop'}]}).encode()
            if status != 200:
                body = b'synthetic-secret-sentinel-error-body'
            writer.write(f'HTTP/1.1 {status} Fixture\r\nContent-Type: application/json\r\nContent-Length: {len(body)}\r\nConnection: close\r\nX-Secret: synthetic-secret-sentinel-header\r\n\r\n'.encode())
            await writer.drain()
            if scenario == 'body':
                writer.write(body[:1])
                await writer.drain()
                await asyncio.sleep(1)
            elif scenario == 'overall':
                for byte in body:
                    writer.write(bytes([byte]))
                    await writer.drain()
                    await asyncio.sleep(0.03)
            else:
                writer.write(body)
                await writer.drain()
        except (ConnectionError, asyncio.IncompleteReadError):
            pass
        finally:
            writer.close()
            handlers.discard(current)
    server = await asyncio.start_server(connection, '127.0.0.1', 0)
    port = server.sockets[0].getsockname()[1]
    scheme = 'https' if scenario in {'setup', 'short-overall'} else 'http'
    value = {'base': f'{scheme}://127.0.0.1:{port}/v1', 'scenario': scenario,
             'overall': 0.08 if scenario == 'short-overall' else (0.45 if scenario == 'overall' else 2),
             'setup': 0.15, 'idle': 0.18 if scenario in {'body', 'overall'} else 1}
    try:
        process = await asyncio.create_subprocess_exec(str(BINARY), '--selftest',
            env={**os.environ, 'VERA_TASK_TRANSPORT_FIXTURE': json.dumps(value)},
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
        stdout, stderr = await asyncio.wait_for(process.communicate(), 8)
        assert process.returncode == 0, (stdout.decode(), stderr.decode())
        result = json.loads(stdout.decode().splitlines()[-1])
        timing = result['timing']
        assert timing['outcome'] == expected
        assert set(timing) <= {'phase', 'outcome', 'status', 'setupSeconds', 'headersSeconds', 'finishSeconds', 'dnsSeconds', 'connectSeconds', 'tlsSeconds'}
        assert timing['phase'] == 'synthesize'
        assert 'synthetic-secret-sentinel' not in stdout.decode()
        assert timing['finishSeconds'] < value['overall'] + 0.3
        assert result['failure'] == (None if expected == 'completed' else 'canceled' if expected == 'canceled' else 'request_timeout' if expected.endswith('timeout') else expected)
        if scenario == 'headers':
            assert uploaded.is_set() and timing['setupSeconds'] < value['setup']
            assert timing['headersSeconds'] >= 0.35
            assert timing['finishSeconds'] > 0.2
            assert timing['status'] == 200
        print(json.dumps({'scenario': scenario, **timing}, sort_keys=True))
    finally:
        server.close()
        await server.wait_closed()
        for task in handlers:
            task.cancel()
        if handlers:
            await asyncio.gather(*list(handlers), return_exceptions=True)
