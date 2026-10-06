import asyncio
import hashlib
import json
import os
import shutil
import signal
import sqlite3
import subprocess
import sys
import time
import uuid
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from pi_assistant.bridge import create_app
from pi_assistant.native import NativeMockTransport
from pi_assistant.process import PiFailure
from pi_assistant.runtime import Runtime
from routers.task_store import TaskConflict

NODE = shutil.which('node')
HELPER = Path(__file__).resolve().parents[2] / 'native-transport/.build/debug/VeraNativeTransport'


def body(text='/task fix the synthetic addition fixture', **changes):
    return {**{key: str(uuid.uuid4()) for key in ('assistant_id', 'conversation_id', 'message_id')}, 'text': text, 'mode': 'assistant', **changes}


def native_rows(root):
    with sqlite3.connect(root / 'native-transport/ledger/spend.sqlite') as db:
        db.row_factory = sqlite3.Row
        return [dict(row) for row in db.execute('SELECT * FROM requests ORDER BY created')]


async def wait_state(runtime, task_id, states, timeout=12):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        task = runtime.store.get(task_id)
        if task['state'] in states:
            return task
        await asyncio.sleep(.01)
    raise AssertionError(runtime.store.get(task_id))


async def approve(runtime, task_id):
    task = await wait_state(runtime, task_id, {'needs_decision'})
    runtime.store.respond(task_id, task['decision']['id'], 'decision:' + task['decision']['id'], {'approved': True})


async def wait_reservation(root, task_id):
    for _ in range(600):
        with sqlite3.connect(root / 'native-transport/ledger/spend.sqlite') as db:
            found = db.execute("SELECT requests.id FROM requests JOIN sessions ON requests.session=sessions.id WHERE sessions.task_id=? AND requests.status='reserved'", (task_id,)).fetchone()
        if found:
            return found[0]
        await asyncio.sleep(.005)
    raise AssertionError('No native reservation')


@pytest.mark.asyncio
async def test_actual_sdk_native_worker_foreground_receipts_and_reopen(tmp_path):
    runtime = Runtime(tmp_path, NODE, native_mock_helper=HELPER)
    await runtime.start()
    request = body()
    pid = runtime.native.process.pid
    try:
        assert runtime.process.timeout == 150
        accepted = await runtime.message(request)
        task_id = accepted['task_ids'][0]
        assert await runtime.message(request) == accepted
        await approve(runtime, task_id)
        await wait_reservation(tmp_path, task_id)
        second = await runtime.message(body('still here?', assistant_id=request['assistant_id'], conversation_id=request['conversation_id']))
        assert second['text'] == 'Native helper fixture reply.'
        assert runtime.store.get(task_id)['state'] == 'running'
        task = await wait_state(runtime, task_id, {'completed'})
        assert task['result']['transport'] == 'native-mock'
        assert Path(task['result']['artifacts'][0]['path']).read_text() == 'def add(a, b):\n    return a + b\n'
        for _ in range(3):
            assert sum(m['id'] == 'task:' + task_id for m in runtime.messages(request['conversation_id'])['messages']) == 1
        rows = native_rows(tmp_path)
        assert len(rows) == 7 and {r['status'] for r in rows} == {'completed'}
        assert sum(r['charged'] for r in rows) == 196000
        with sqlite3.connect(tmp_path / 'native-transport/ledger/spend.sqlite') as db:
            scopes = {r[0] for r in db.execute("SELECT task_id FROM sessions WHERE task_id!=''")}
            assert request['message_id'] in scopes and task_id in scopes and len(scopes) == 3
            assert db.execute('SELECT credential_attempted FROM experiments').fetchone()[0] == 1
        for file in (tmp_path / 'native-transport').rglob('*'):
            if file.is_file():
                assert b'synthetic-broker-key' not in file.read_bytes()
        with runtime.connect() as db:
            assert db.execute('SELECT COUNT(*) FROM effects').fetchone()[0] == 1
    finally:
        await runtime.stop()
    with pytest.raises(ProcessLookupError):
        os.kill(pid, 0)
    reopened = Runtime(tmp_path, NODE, native_mock_helper=HELPER)
    await reopened.start()
    try:
        assert await reopened.message(request) == accepted
        assert len(native_rows(tmp_path)) == 7
        assert sum(m['id'] == 'task:' + task_id for m in reopened.messages(request['conversation_id'])['messages']) == 1
        with pytest.raises(PiFailure):
            await reopened.message(body('a third foreground turn'))
        assert len(native_rows(tmp_path)) == 7
    finally:
        await reopened.stop()


@pytest.mark.asyncio
async def test_native_cancel_preserves_other_role_and_uncertain_budget(tmp_path):
    runtime = Runtime(tmp_path, NODE, native_mock_helper=HELPER)
    await runtime.start()
    request = body()
    foreground = None
    try:
        task_id = (await runtime.message(request))['task_ids'][0]
        await approve(runtime, task_id)
        await wait_reservation(tmp_path, task_id)
        second = body('still here?', assistant_id=request['assistant_id'], conversation_id=request['conversation_id'])
        foreground = asyncio.create_task(runtime.message(second))
        await wait_reservation(tmp_path, second['message_id'])
        runtime.store.cancel(task_id)
        assert (await foreground)['text'] == 'Native helper fixture reply.'
        await wait_state(runtime, task_id, {'canceled'})
        rows = native_rows(tmp_path)
        assert len(rows) == 4
        assert sum(r['status'] == 'uncertain' for r in rows) == 1
        assert not runtime.process.pids
        assert runtime.native.process.returncode is None
        with runtime.connect() as db:
            assert db.execute('SELECT COUNT(*) FROM effects').fetchone()[0] == 0
        native = runtime.native
        retry = {'type': 'model', 'id': str(uuid.uuid4()), 'context': {'messages': [{'role': 'user', 'content': 'retry'}]}}
        with pytest.raises(PiFailure):
            await native.complete(retry, task_id, 'worker', 'assistant')
        assert len(native_rows(tmp_path)) == 4
    finally:
        if foreground and not foreground.done():
            foreground.cancel()
            await asyncio.gather(foreground, return_exceptions=True)
        await runtime.stop()


@pytest.mark.asyncio
async def test_native_helper_kill_retains_task_and_blocks_replay(tmp_path):
    runtime = Runtime(tmp_path, NODE, native_mock_helper=HELPER)
    await runtime.start()
    request = body()
    task_id = (await runtime.message(request))['task_ids'][0]
    try:
        await approve(runtime, task_id)
        await wait_reservation(tmp_path, task_id)
        runtime.native.process.kill()
        await runtime.native.process.wait()
        await wait_state(runtime, task_id, {'needs_decision'})
        assert len(native_rows(tmp_path)) == 3
        with runtime.connect() as db:
            assert db.execute('SELECT COUNT(*) FROM effects').fetchone()[0] == 0
    finally:
        await runtime.stop()
    reopened = Runtime(tmp_path, NODE, native_mock_helper=HELPER)
    await reopened.start()
    try:
        assert await reopened.message(request)
        await approve(reopened, task_id)
        await wait_state(reopened, task_id, {'needs_decision'})
        rows = native_rows(tmp_path)
        assert len(rows) == 3 and rows[-1]['status'] == 'uncertain'
        assert len(reopened.task_ids(request['message_id'])) == 1
    finally:
        await reopened.stop()


def test_native_http_focused_and_declined_task(tmp_path):
    with TestClient(create_app(tmp_path, NODE, HELPER)) as client:
        cap = client.get('/assistant/capabilities').json()
        assert cap['transport'] == 'mock' and cap['transport_detail'] == 'native-mock'
        request = body('/task do not delegate in focused mode', mode='focused')
        result = client.post('/assistant/messages', json=request)
        assert result.status_code == 200 and result.json()['task_ids'] == []
        accepted = client.post('/assistant/messages', json=body()).json()
        runtime = client.app.state.runtime
        task_id = accepted['task_ids'][0]
        for _ in range(300):
            task = runtime.store.get(task_id)
            if task['state'] == 'needs_decision':
                break
            time.sleep(.01)
        runtime.store.respond(task_id, task['decision']['id'], 'decline', {'approved': False})
        for _ in range(300):
            if runtime.store.get(task_id)['state'] == 'failed':
                break
            time.sleep(.01)
        assert runtime.store.get(task_id)['state'] == 'failed'
        assert len(native_rows(tmp_path)) == 3
        assert not (runtime.workspace / task_id).exists()


@pytest.mark.asyncio
async def test_native_client_eof_settles_pending_and_reaps(tmp_path):
    native = NativeMockTransport(tmp_path / 'native-transport', HELPER)
    await native.start()
    task_id = str(uuid.uuid4())
    event = {'type': 'model', 'id': str(uuid.uuid4()), 'context': {'messages': [{'role': 'user', 'content': 'fixture'}]}}
    call = asyncio.create_task(native.complete(event, task_id, 'foreground', 'assistant'))
    await wait_reservation(tmp_path, task_id)
    pid = native.process.pid
    await native.stop()
    with pytest.raises(PiFailure):
        await call
    assert native_rows(tmp_path)[0]['status'] == 'uncertain'
    assert not native.pending
    with pytest.raises(ProcessLookupError):
        os.kill(pid, 0)


@pytest.mark.asyncio
@pytest.mark.parametrize('first_native', [True, False])
async def test_transport_change_cannot_execute_persisted_task(tmp_path, first_native):
    original = Runtime(tmp_path, NODE, native_mock_helper=HELPER if first_native else None)
    await original.start()
    request = body()
    task_id = (await original.message(request))['task_ids'][0]
    await wait_state(original, task_id, {'needs_decision'})
    await original.stop()
    changed = Runtime(tmp_path, NODE, native_mock_helper=None if first_native else HELPER)
    await changed.start()
    try:
        await approve(changed, task_id)
        failed = await wait_state(changed, task_id, {'failed'})
        assert failed['result'] is None
        assert not (changed.workspace / task_id).exists()
        with changed.connect() as db:
            assert db.execute('SELECT COUNT(*) FROM effects').fetchone()[0] == 0
    finally:
        await changed.stop()


@pytest.mark.asyncio
async def test_protocol_failure_terminates_helper_without_explicit_stop(tmp_path):
    helper = tmp_path / 'bad-helper'
    helper.write_text('#!/bin/sh\nprintf \'{"type":"ready","transport":"native-mock"}\\n\'\nread request\nprintf \'{"request_id":"00000000-0000-0000-0000-000000000000","ok":true,"content":[]}\\n\'\nsleep 30 &\nwait\n')
    helper.chmod(0o700)
    native = NativeMockTransport(tmp_path / 'native-transport', helper)
    await native.start()
    try:
        event = {'type': 'model', 'id': str(uuid.uuid4()), 'context': {'messages': [{'role': 'user', 'content': 'fixture'}]}}
        with pytest.raises(PiFailure):
            await native.complete(event, str(uuid.uuid4()), 'foreground', 'assistant')
        await asyncio.wait_for(native.reader, 4)
        assert native.process.returncode is not None and not native.pending
        with native.connect() as db:
            assert db.execute('SELECT state FROM requests').fetchone()[0] == 'pending'
    finally:
        await native.stop()


@pytest.mark.asyncio
async def test_cancel_before_pipe_write_does_not_kill_other_role(tmp_path):
    native = NativeMockTransport(tmp_path / 'native-transport', HELPER)
    await native.start()
    worker_id = str(uuid.uuid4())
    event = lambda: {'type': 'model', 'id': str(uuid.uuid4()), 'context': {'messages': [{'role': 'user', 'content': 'fixture'}]}}
    worker = asyncio.create_task(native.complete(event(), worker_id, 'worker', 'assistant'))
    await wait_reservation(tmp_path, worker_id)
    await native.write_lock.acquire()
    queued = asyncio.create_task(native.complete(event(), str(uuid.uuid4()), 'foreground', 'assistant'))
    try:
        await asyncio.sleep(.02)
        queued.cancel()
        with pytest.raises(asyncio.CancelledError):
            await queued
        assert native.process.returncode is None
    finally:
        native.write_lock.release()
    try:
        assert (await worker)['ok'] is True
        rows = native_rows(tmp_path)
        assert len(rows) == 1 and rows[0]['status'] == 'completed'
        with native.connect() as db:
            assert db.execute("SELECT COUNT(*) FROM requests WHERE state='unsent'").fetchone()[0] == 1
    finally:
        await native.stop()


@pytest.mark.asyncio
async def test_two_foreground_conversations_queue_without_interrupted_turn(tmp_path):
    runtime = Runtime(tmp_path, NODE, native_mock_helper=HELPER)
    await runtime.start()
    requests = [body('Unicode café 🙂 ' + str(i), mode='focused') for i in range(2)]
    try:
        answers = await asyncio.gather(*(runtime.message(r) for r in requests))
        assert all(a['task_ids'] == [] for a in answers)
        with runtime.connect() as db:
            assert db.execute("SELECT COUNT(*) FROM turns WHERE state='completed'").fetchone()[0] == 2
        assert len(native_rows(tmp_path)) == 2
    finally:
        await runtime.stop()


@pytest.mark.asyncio
async def test_parent_sigkill_closes_helper_and_node_then_recovers_once(tmp_path):
    program = '''
import asyncio,json,os,sys
from pathlib import Path
from pi_assistant.runtime import Runtime
async def main():
 root=Path(sys.argv[1]); request=json.loads(sys.argv[4])
 runtime=Runtime(root,sys.argv[2],native_mock_helper=Path(sys.argv[3]))
 await runtime.start()
 task_id=(await runtime.message(request))['task_ids'][0]
 while runtime.store.get(task_id)['state']!='needs_decision': await asyncio.sleep(.005)
 task=runtime.store.get(task_id)
 runtime.store.respond(task_id,task['decision']['id'],'approve',{'approved':True})
 import sqlite3
 while True:
  with sqlite3.connect(root/'native-transport/ledger/spend.sqlite') as db:
   found=db.execute("SELECT requests.id FROM requests JOIN sessions ON requests.session=sessions.id WHERE sessions.task_id=? AND requests.status='reserved'",(task_id,)).fetchone()
  if found: break
  await asyncio.sleep(.005)
 (root/'child-ready.json').write_text(json.dumps({'task_id':task_id,'helper':runtime.native.process.pid,'nodes':list(runtime.process.pids)}))
 await asyncio.sleep(60)
asyncio.run(main())
'''
    request = body()
    env = {'PATH': '/usr/bin:/bin', 'LANG': 'C.UTF-8', 'PYTHONDONTWRITEBYTECODE': '1',
           'PYTHONPATH': os.pathsep.join(sys.path)}
    child = subprocess.Popen([sys.executable, '-c', program, str(tmp_path), NODE, str(HELPER), json.dumps(request)],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=env, start_new_session=True)
    evidence = None
    try:
        for _ in range(1000):
            try:
                evidence = json.loads((tmp_path / 'child-ready.json').read_text())
                break
            except (FileNotFoundError, json.JSONDecodeError):
                assert child.poll() is None
                await asyncio.sleep(.01)
        assert evidence and evidence['nodes']
        os.killpg(child.pid, signal.SIGKILL)
        child.wait(timeout=3)
        for pid in [evidence['helper'], *evidence['nodes']]:
            for _ in range(600):
                try:
                    os.kill(pid, 0)
                except ProcessLookupError:
                    break
                await asyncio.sleep(.01)
            else:
                raise AssertionError('Prototype descendant survived parent SIGKILL')
        reopened = Runtime(tmp_path, NODE, native_mock_helper=HELPER)
        await reopened.start()
        try:
            assert await reopened.message(request)
            task_id = evidence['task_id']
            await wait_state(reopened, task_id, {'needs_decision'})
            assert reopened.task_ids(request['message_id']) == [task_id]
            rows = native_rows(tmp_path)
            assert len(rows) == 3 and rows[-1]['status'] == 'uncertain'
            with reopened.connect() as db:
                assert db.execute('SELECT COUNT(*) FROM effects').fetchone()[0] == 0
        finally:
            await reopened.stop()
    finally:
        if child.poll() is None:
            os.killpg(child.pid, signal.SIGKILL)
            child.wait(timeout=3)
        if evidence:
            for pid in [evidence['helper'], *evidence['nodes']]:
                try:
                    os.killpg(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass


@pytest.mark.asyncio
async def test_helper_dies_before_queued_write_marks_unsent(tmp_path):
    native = NativeMockTransport(tmp_path / 'native-transport', HELPER)
    await native.start()
    await native.write_lock.acquire()
    event = {'type': 'model', 'id': str(uuid.uuid4()), 'context': {'messages': [{'role': 'user', 'content': 'fixture'}]}}
    call = asyncio.create_task(native.complete(event, str(uuid.uuid4()), 'foreground', 'assistant'))
    try:
        for _ in range(100):
            if event['id'] in native.pending:
                break
            await asyncio.sleep(.01)
        assert event['id'] in native.pending
        native.process.kill()
        await asyncio.wait_for(native.reader, 4)
    finally:
        native.write_lock.release()
    try:
        with pytest.raises(PiFailure):
            await call
        assert not native.pending
        with native.connect() as db:
            assert db.execute('SELECT state FROM requests WHERE id=?', (event['id'],)).fetchone()[0] == 'unsent'
        assert native_rows(tmp_path) == []
    finally:
        await native.stop()


@pytest.mark.asyncio
async def test_cancel_preserves_cancellation_when_unsent_storage_fails(tmp_path, monkeypatch):
    native = NativeMockTransport(tmp_path / 'native-transport', HELPER)
    await native.start()
    await native.write_lock.acquire()
    event = {'type': 'model', 'id': str(uuid.uuid4()), 'context': {'messages': [{'role': 'user', 'content': 'fixture'}]}}
    call = asyncio.create_task(native.complete(event, str(uuid.uuid4()), 'foreground', 'assistant'))
    try:
        for _ in range(100):
            if event['id'] in native.pending:
                break
            await asyncio.sleep(.01)
        assert event['id'] in native.pending
        def unavailable():
            raise sqlite3.OperationalError('fixture failure')
        monkeypatch.setattr(native, 'connect', unavailable)
        call.cancel()
        with pytest.raises(asyncio.CancelledError):
            await call
        assert not native.pending and native.failed
    finally:
        native.write_lock.release()
        await native.stop()


@pytest.mark.asyncio
async def test_legacy_native_ledger_refused_without_migration(tmp_path):
    native = NativeMockTransport(tmp_path / 'native-transport', HELPER)
    await native.start()
    await native.stop()
    path = native.root / 'ledger/spend.sqlite'
    with sqlite3.connect(path) as db:
        assert db.execute('PRAGMA user_version').fetchone()[0] == 2
        db.execute('PRAGMA user_version=1')
        before = db.execute('SELECT * FROM experiments').fetchall()
    reopened = NativeMockTransport(tmp_path / 'native-transport', HELPER)
    with pytest.raises(PiFailure):
        await reopened.start()
    with sqlite3.connect(path) as db:
        assert db.execute('PRAGMA user_version').fetchone()[0] == 1
        assert db.execute('SELECT * FROM experiments').fetchall() == before
    assert reopened.process.returncode is not None


def test_host_scope_mode_is_immutable(tmp_path):
    native = NativeMockTransport(tmp_path / 'native-transport', HELPER)
    task_id = str(uuid.uuid4())
    slot = native._slot(task_id, 'foreground', 'focused')
    with pytest.raises(PiFailure, match='native_scope_mode'):
        native._slot(task_id, 'foreground', 'assistant')
    assert native._slot(task_id, 'foreground', 'focused') == slot
