import asyncio
import hashlib
import json
import os
import shutil
import signal
import subprocess
import sys
import time
import uuid
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from pi_assistant.bridge import create_app
from pi_assistant.process import PiFailure, PiProcess
from pi_assistant.runtime import Runtime
from routers.task_store import TaskConflict

NODE = shutil.which('node')


def body(text='/task fix the synthetic addition fixture', **changes):
    return {**{key: str(uuid.uuid4()) for key in ('assistant_id', 'conversation_id', 'message_id')}, 'text': text, 'mode': 'assistant', **changes}


async def wait_state(runtime, task_id, states, timeout=8):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        task = runtime.store.get(task_id)
        if task['state'] in states:
            return task
        await asyncio.sleep(.02)
    raise AssertionError(runtime.store.get(task_id))


async def approve(runtime, task_id):
    task = await wait_state(runtime, task_id, {'needs_decision'})
    return runtime.store.respond(task_id, task['decision']['id'], 'decision:' + task['decision']['id'], {'approved': True})


@pytest.mark.asyncio
async def test_independent_worker_second_reply_delivery_once(tmp_path):
    runtime = Runtime(tmp_path, NODE, worker_delay_ms=400)
    await runtime.start()
    request = body()
    try:
        accepted = await runtime.message(request)
        assert await runtime.message(request) == accepted
        task_id = accepted['task_ids'][0]
        await approve(runtime, task_id)
        await wait_state(runtime, task_id, {'running'})
        second = await runtime.message(body('still here?', assistant_id=request['assistant_id'], conversation_id=request['conversation_id']))
        assert second['text'] == 'Mock reply: still here?'
        assert runtime.store.get(task_id)['state'] == 'running'
        task = await wait_state(runtime, task_id, {'completed'})
        assert Path(task['result']['artifacts'][0]['path']).read_text() == 'def add(a, b):\n    return a + b\n'
        for _ in range(3):
            assert sum(x['id'] == 'task:' + task_id for x in runtime.messages(request['conversation_id'])['messages']) == 1
        with runtime.connect() as db:
            assert db.execute('SELECT COUNT(*) FROM effects').fetchone()[0] == 1
    finally:
        await runtime.stop()
    reopened = Runtime(tmp_path, NODE)
    await reopened.start()
    try:
        assert await reopened.message(request) == accepted
        assert sum(x['id'] == 'task:' + task_id for x in reopened.messages(request['conversation_id'])['messages']) == 1
    finally:
        await reopened.stop()


@pytest.mark.asyncio
async def test_approval_survives_restart_and_rejects_stale_reply(tmp_path):
    runtime = Runtime(tmp_path, NODE)
    await runtime.start()
    request = body()
    task_id = (await runtime.message(request))['task_ids'][0]
    task = await wait_state(runtime, task_id, {'needs_decision'})
    await runtime.stop()
    assert not (runtime.workspace / task_id).exists()
    reopened = Runtime(tmp_path, NODE)
    await reopened.start()
    try:
        assert reopened.store.get(task_id)['decision'] == task['decision']
        with pytest.raises(TaskConflict):
            reopened.store.respond(task_id, 'stale', 'reply', {'approved': True})
        reopened.store.cancel(task_id)
        with pytest.raises(TaskConflict):
            reopened.store.respond(task_id, task['decision']['id'], 'reply', {'approved': True})
        assert reopened.store.get(task_id)['state'] == 'canceled'
    finally:
        await reopened.stop()


@pytest.mark.asyncio
async def test_cancel_running_terminates_worker_and_no_result(tmp_path):
    runtime = Runtime(tmp_path, NODE, worker_delay_ms=1000)
    await runtime.start()
    try:
        task_id = (await runtime.message(body()))['task_ids'][0]
        await approve(runtime, task_id)
        await wait_state(runtime, task_id, {'running'})
        await asyncio.sleep(.1)
        pids = list(runtime.process.pids)
        assert pids
        runtime.store.cancel(task_id)
        await wait_state(runtime, task_id, {'canceled'})
        await asyncio.sleep(.1)
        assert not runtime.process.pids
        for pid in pids:
            with pytest.raises(ProcessLookupError):
                os.kill(pid, 0)
        assert runtime.store.get(task_id)['result'] is None
    finally:
        await runtime.stop()


@pytest.mark.asyncio
async def test_effect_reconciliation_and_external_edit_fence(tmp_path):
    runtime = Runtime(tmp_path, NODE)
    task = runtime.store.create('pi_worker', {}, 'effect-fixture')
    task = runtime.store.claim(('pi_worker',))
    directory = runtime.workspace / task['id']
    directory.mkdir()
    source = directory / 'sum.py'
    source.write_text('before')
    event = {'name': 'write_file', 'args': {'path': 'sum.py', 'content': 'after'}}
    assert runtime.file_tool(task, directory, event)['reconciled'] is False
    before = source.stat().st_mtime_ns
    with runtime.connect() as db:
        db.execute("UPDATE effects SET state='intent'")
    assert runtime.file_tool(task, directory, event)['reconciled'] is True
    assert source.stat().st_mtime_ns == before
    source.write_text('external edit')
    with pytest.raises(ValueError):
        runtime.file_tool(task, directory, event)
    source.unlink()
    source.symlink_to(tmp_path / 'outside')
    with pytest.raises(OSError):
        runtime.file_tool(task, directory, event)
    with pytest.raises(ValueError):
        runtime.file_tool(task, directory, {'name': 'write_file', 'args': {'path': '../outside', 'content': 'bad'}})


def test_http_contract_and_local_boundary(tmp_path):
    with TestClient(create_app(tmp_path, NODE)) as client:
        cap = client.get('/assistant/capabilities').json()
        assert cap['transport'] == 'mock' and cap['computers'] is False
        request = body('hello', mode='focused')
        answer = client.post('/assistant/messages', json=request)
        assert answer.status_code == 200
        assert answer.json()['task_ids'] == []
        assert client.post('/assistant/messages', json=request).json() == answer.json()
        assert client.post('/assistant/messages', json={**request, 'text': 'changed'}).status_code == 409
        assert client.post('/tasks', json={'worker_type': 'pi_worker', 'payload': {}, 'idempotency_key': 'bad'}).status_code == 422
        assert client.get('/assistant/capabilities', headers={'Origin': 'https://example.org'}).status_code == 403
        assert client.get('/assistant/capabilities', headers={'Host': 'evil.example'}).status_code == 403
        assert client.post('/assistant/messages', content='{}').status_code == 415
        assert len(client.get('/assistant/messages', params={'conversation_id': request['conversation_id']}).json()['messages']) == 2


@pytest.mark.asyncio
async def test_protocol_timeout_malformed_and_descendant_cleanup(tmp_path):
    child = tmp_path / 'child.mjs'
    descendant_file = tmp_path / 'pid'
    child.write_text("import {spawn} from 'node:child_process'; import {writeFileSync} from 'node:fs'; const p=spawn(process.execPath,['-e',\"process.on('SIGTERM',()=>{});setInterval(()=>{},1000)\"],{stdio:'ignore'});writeFileSync(process.argv[1]+'.pid',String(p.pid));process.on('SIGTERM',()=>{});setInterval(()=>{},1000);")
    proc = PiProcess(NODE, child, timeout=.3)
    async def host(event):
        raise ValueError('no tools')
    with pytest.raises(PiFailure, match='timeout'):
        await proc.run({}, host)
    descendant = int(Path(str(child) + '.pid').read_text())
    for _ in range(50):
        try:
            os.kill(descendant, 0)
        except ProcessLookupError:
            break
        await asyncio.sleep(.02)
    else:
        raise AssertionError('live descendant survived')
    child.write_text("process.stdout.write('not-json\\n');setInterval(()=>{},1000)")
    with pytest.raises(PiFailure, match='protocol'):
        await proc.run({}, host)


@pytest.mark.asyncio
async def test_completed_receipt_recovers_without_execution(tmp_path):
    runtime = Runtime(tmp_path, NODE)
    request = body()
    payload = {'assistant_id': request['assistant_id'], 'conversation_id': request['conversation_id'], 'originating_message_id': request['message_id'], 'objective': 'fixture'}
    task = runtime.store.create('pi_worker', payload, 'accepted-before-kill')
    task = runtime.store.claim(('pi_worker',))
    from routers.task_store import StepResult
    runtime.store.commit_step(task['id'], task['generation'], StepResult(checkpoint={'approved': True}))
    claimed = runtime.store.claim(('pi_worker',))
    with runtime.connect() as db:
        db.execute('INSERT INTO attempts VALUES(?,?,?)', (task['id'], 'completed', json.dumps({'summary': 'Saved result', 'artifacts': []})))
    await runtime.start()
    try:
        complete = await wait_state(runtime, task['id'], {'completed'})
        assert complete['result']['summary'] == 'Saved result'
        assert not runtime.process.pids
        assert len(runtime.messages(request['conversation_id'])['messages']) == 1
    finally:
        await runtime.stop()


@pytest.mark.asyncio
async def test_real_sigkill_after_effect_requires_decision_and_no_duplicate_write(tmp_path):
    marker = tmp_path / 'marker.json'
    state = tmp_path / 'state'
    runner = tmp_path / 'crash.py'
    runner.write_text('''import asyncio,json,shutil,sys
from pathlib import Path
from pi_assistant.runtime import Runtime
async def main():
 r=Runtime(Path(sys.argv[1]),shutil.which('node'),worker_delay_ms=450)
 await r.start()
 request=json.loads(sys.argv[3])
 task_id=(await r.message(request))['task_ids'][0]
 while r.store.get(task_id)['state'] != 'needs_decision': await asyncio.sleep(.02)
 t=r.store.get(task_id)
 r.store.respond(task_id,t['decision']['id'],'approve',{'approved':True})
 while True:
  with r.connect() as db: effect=db.execute("SELECT state FROM effects WHERE task_id=?",(task_id,)).fetchone()
  if effect and effect['state']=='applied':
   Path(sys.argv[2]).write_text(json.dumps({'task_id':task_id,'pids':list(r.process.pids)}))
   break
  await asyncio.sleep(.01)
 await asyncio.Event().wait()
asyncio.run(main())
''')
    request = body()
    process = subprocess.Popen([sys.executable, str(runner), str(state), str(marker), json.dumps(request)], env={**os.environ, 'PYTHONDONTWRITEBYTECODE': '1'}, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(400):
            if marker.exists():
                break
            assert process.poll() is None
            await asyncio.sleep(.02)
        assert marker.exists()
        evidence = json.loads(marker.read_text())
        source = state / 'workspaces' / evidence['task_id'] / 'sum.py'
        modified = source.stat().st_mtime_ns
        process.kill()
        process.wait(timeout=2)
        for _ in range(100):
            live = []
            for pid in evidence['pids']:
                try:
                    os.kill(pid, 0)
                    live.append(pid)
                except ProcessLookupError:
                    pass
            if not live:
                break
            await asyncio.sleep(.02)
        assert not live
        runtime = Runtime(state, NODE)
        await runtime.start()
        try:
            task = await wait_state(runtime, evidence['task_id'], {'needs_decision'})
            assert task['checkpoint']['approved'] is True
            assert source.stat().st_mtime_ns == modified
            await approve(runtime, task['id'])
            await wait_state(runtime, task['id'], {'completed'})
            assert source.stat().st_mtime_ns == modified
            assert sum(x['id'] == 'task:' + task['id'] for x in runtime.messages(request['conversation_id'])['messages']) == 1
        finally:
            await runtime.stop()
    finally:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=2)


@pytest.mark.asyncio
@pytest.mark.parametrize('denied', ['read_file', 'write_file', 'check_python'])
async def test_denied_tool_never_publishes_success(tmp_path, denied):
    runtime = Runtime(tmp_path, NODE)
    original = runtime.file_tool
    def deny(task, directory, event):
        if event['name'] == denied:
            raise ValueError('Denied by host')
        return original(task, directory, event)
    runtime.file_tool = deny
    await runtime.start()
    request = body()
    try:
        task_id = (await runtime.message(request))['task_ids'][0]
        await approve(runtime, task_id)
        result = await wait_state(runtime, task_id, {'completed', 'failed'})
        assert result['state'] == 'failed'
        assert result['result'] is None
        assert not any(x['id'] == 'task:' + task_id for x in runtime.messages(request['conversation_id'])['messages'])
    finally:
        await runtime.stop()


@pytest.mark.asyncio
async def test_symlink_task_directory_cannot_initialize_outside_file(tmp_path):
    runtime = Runtime(tmp_path / 'state', NODE)
    outside = tmp_path / 'outside'
    outside.mkdir()
    await runtime.start()
    try:
        task_id = (await runtime.message(body()))['task_ids'][0]
        await wait_state(runtime, task_id, {'needs_decision'})
        (runtime.workspace / task_id).symlink_to(outside, target_is_directory=True)
        await approve(runtime, task_id)
        task = await wait_state(runtime, task_id, {'completed', 'failed'})
        assert task['state'] == 'failed'
        assert not (outside / 'sum.py').exists()
    finally:
        await runtime.stop()


def test_symlink_workspace_root_rejected(tmp_path):
    state = tmp_path / 'state'
    state.mkdir()
    outside = tmp_path / 'outside'
    outside.mkdir()
    (state / 'workspaces').symlink_to(outside, target_is_directory=True)
    with pytest.raises(OSError):
        Runtime(state, NODE)
    assert not list(outside.iterdir())


@pytest.mark.asyncio
async def test_timeout_kills_process_before_stubborn_host_settles(tmp_path):
    child = tmp_path / 'host.mjs'
    child.write_text("process.stdout.write(JSON.stringify({type:'tool',id:'one',name:'fixture',args:{}})+'\\n');setInterval(()=>{},1000)")
    proc = PiProcess(NODE, child, timeout=.1)
    entered = asyncio.Event()
    released = asyncio.Event()
    async def stubborn(event):
        entered.set()
        try:
            await asyncio.sleep(10)
        except asyncio.CancelledError:
            await released.wait()
        return {}
    invocation = asyncio.create_task(proc.run({}, stubborn))
    await entered.wait()
    pids = list(proc.pids)
    await asyncio.sleep(.5)
    assert proc.cleanup_blocked
    assert not proc.pids
    assert not invocation.done()
    for pid in pids:
        with pytest.raises(ProcessLookupError):
            os.kill(pid, 0)
    released.set()
    with pytest.raises(PiFailure, match='timeout'):
        await asyncio.wait_for(invocation, 1)
    assert not proc.cleanup_blocked


@pytest.mark.asyncio
async def test_deliveries_keep_chronological_order_and_recent_context(tmp_path):
    runtime = Runtime(tmp_path, NODE)
    await runtime.start()
    request = body()
    try:
        task_id = (await runtime.message(request))['task_ids'][0]
        await approve(runtime, task_id)
        await wait_state(runtime, task_id, {'completed'})
        for index in range(16):
            with runtime.connect() as db:
                db.execute('INSERT INTO deliveries VALUES(?,?,?,?)', ('older:' + str(index), request['conversation_id'], json.dumps({'id': 'older:' + str(index), 'role': 'assistant', 'text': 'old task', 'task_ids': []}), index))
        later = body('later message', assistant_id=request['assistant_id'], conversation_id=request['conversation_id'])
        reply = await runtime.message(later)
        transcript = runtime.messages(request['conversation_id'])['messages']
        assert transcript[-1]['id'] == reply['reply_id']
        assert transcript[-2]['id'] == later['message_id']
        assert transcript[-3]['id'] == 'task:' + task_id
        captured = []
        original = runtime.process.run
        async def capture(config, host, canceled=lambda: False):
            captured.extend(config['history'])
            return await original(config, host, canceled)
        runtime.process.run = capture
        await runtime.message(body('third', assistant_id=request['assistant_id'], conversation_id=request['conversation_id']))
        assert captured[-2]['content'] == 'later message'
        assert captured[-1]['content'][0]['text'] == reply['text']
    finally:
        await runtime.stop()
