import json
import os
import select
import shutil
import signal
import sqlite3
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[3]
BINARY = REPO / 'apps/vera-mac/.build/debug/Vera'


def uid():
    return str(uuid.uuid4())


def body(text='/task fix the disposable fixture', **changes):
    return {**{key: uid() for key in ('assistant_id', 'conversation_id', 'message_id')}, 'text': text, 'mode': 'assistant', **changes}


def wait_for(operation, predicate, timeout=8):
    until = time.monotonic() + timeout
    while time.monotonic() < until:
        value = operation()
        if predicate(value):
            return value
        time.sleep(.01)
    raise AssertionError('Mock condition deadline exceeded')


def gone(pid):
    try:
        os.kill(pid, 0)
        return False
    except ProcessLookupError:
        return True


def descendants(pid):
    pairs = [line.split() for line in subprocess.check_output(['ps', '-axo', 'pid=,ppid='], text=True).splitlines()]
    found = {pid}
    for _ in range(8):
        found.update(int(child) for child, parent in pairs if int(parent) in found)
    return found - {pid}


class App:
    def __init__(self, root, repo=REPO):
        root = root.resolve()
        self.root = root
        self.buffer = bytearray()
        self.process = subprocess.Popen([str(BINARY), '--pi-broker-mock', '--root', str(root), '--repo', str(repo), '--python', sys.executable, '--node', shutil.which('node'), '--port', '0'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env={'PATH': '/usr/bin:/bin', 'LANG': 'C.UTF-8'})
        try:
            self.ready = self.read()
            assert self.ready['op'] == 'ready'
            self.endpoint = 'http://127.0.0.1:' + str(self.ready['port'])
            self.capability = self.ready['ui_capability']
        except BaseException:
            self.close()
            raise

    def read(self):
        until = time.monotonic() + 10
        while b'\n' not in self.buffer:
            assert time.monotonic() < until, 'Private mock channel timeout'
            if select.select([self.process.stdout], [], [], .1)[0]:
                chunk = os.read(self.process.stdout.fileno(), 4096)
                assert chunk, 'Private mock channel closed'
                self.buffer.extend(chunk)
        line, _, self.buffer = self.buffer.partition(b'\n')
        return json.loads(line)

    def control(self, op, **fields):
        request_id = uid()
        self.process.stdin.write(json.dumps({'op': op, 'id': request_id, **fields}).encode() + b'\n')
        self.process.stdin.flush()
        reply = self.read()
        assert reply.get('id') == request_id
        return reply

    def grant(self, request, task=None):
        result = self.control('authorize', binding={'subject': task or request['message_id'], 'assistant': request['assistant_id'], 'conversation': request['conversation_id'], 'role': 'worker' if task else 'foreground', 'mode': 'assistant' if task else request['mode']})
        assert result['op'] == 'authorized'
        return result['binding']

    def http(self, path, payload=None, authenticated=True, headers=None):
        header = {'Content-Type': 'application/json'}
        if authenticated:
            header['Authorization'] = 'Bearer ' + self.capability
        header.update(headers or {})
        request = urllib.request.Request(self.endpoint + path, data=json.dumps(payload).encode() if payload is not None else None, headers=header)
        try:
            with urllib.request.urlopen(request, timeout=8) as response:
                return response.status, json.load(response)
        except urllib.error.HTTPError as error:
            return error.code, json.load(error)

    def send(self, request):
        status, result = self.http('/assistant/messages', request)
        assert status == 200, 'Mock foreground request failed'
        return result

    def tasks(self):
        status, result = self.http('/tasks')
        assert status == 200
        return result['tasks']

    def task(self, task):
        return next(item for item in self.tasks() if item['id'] == task)

    def approve(self, request, task):
        state = wait_for(lambda: self.task(task), lambda item: item['state'] == 'needs_decision')
        self.grant(request, task)
        status, _ = self.http('/tasks/' + task + '/decision', {'decision_id': state['decision']['id'], 'idempotency_key': uid(), 'reply': {'approved': True}})
        assert status == 200

    def rows(self):
        return self.control('snapshot')['requests']

    def close(self):
        if self.process.stdin and not self.process.stdin.closed:
            self.process.stdin.close()
        try:
            self.process.wait(timeout=7)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait(timeout=2)
            raise AssertionError('Mock app shutdown deadline exceeded')
        self.process.stdout.close()


def test_actual_app_pi_http_responsiveness_and_restart(tmp_path):
    root = tmp_path / 'experiment'
    app = App(root)
    request = body()
    try:
        assert app.http('/assistant/capabilities', authenticated=False)[0] == 403
        assert app.http('/docs', authenticated=False)[0] == 403
        assert app.http('/tasks', headers={'Authorization': 'Bearer invalid'})[0] == 403
        assert app.http('/tasks', headers={'Origin': 'https://invalid.example'})[0] == 403
        assert app.http('/assistant/messages', request)[0] == 503
        assert app.rows() == [] and app.tasks() == []
        app.grant(request)
        mismatched = {**request, 'conversation_id': uid()}
        assert app.http('/assistant/messages', mismatched)[0] == 503
        assert app.rows() == [] and app.tasks() == []
        first = app.send(request)
        task = first['task_ids'][0]
        waiting = wait_for(lambda: app.task(task), lambda item: item['state'] == 'needs_decision')
        assert len(app.rows()) == 2
        assert app.http('/tasks/' + task + '/decision', {'decision_id': waiting['decision']['id'], 'idempotency_key': uid(), 'reply': {'approved': True}}, authenticated=False)[0] == 403
        assert app.task(task)['state'] == 'needs_decision'
        app.approve(request, task)
        wait_for(app.rows, lambda rows: any(row['status'] == 'reserved' for row in rows))
        second = body('Are you available?', assistant_id=request['assistant_id'], conversation_id=request['conversation_id'])
        app.grant(second)
        start = time.monotonic()
        assert app.send(second)['task_ids'] == []
        assert time.monotonic() - start < 1.2
        assert app.task(task)['state'] == 'running'
        completed = wait_for(lambda: app.task(task), lambda item: item['state'] == 'completed')
        artifact = Path(completed['result']['artifacts'][0]['path'])
        assert artifact.resolve().is_relative_to((root / 'runtime/workspaces').resolve())
        assert artifact.read_text() == 'def add(a, b):\n    return a + b\n'
        assert app.send(request) == first and len(app.rows()) == 7
        transcript = app.http('/assistant/messages?conversation_id=' + request['conversation_id'])[1]
        assert len([m for m in transcript['messages'] if m.get('id') == 'task:' + task]) == 1
        focused = body('/task must remain focused', mode='focused')
        app.grant(focused)
        assert app.send(focused)['task_ids'] == []
        assert all(row['charged'] == 28000 for row in app.rows())
        original_profile, old_cap = app.ready['profile'], app.capability
        children = descendants(app.process.pid)
    finally:
        app.close()
    for pid in children:
        wait_for(lambda: gone(pid), bool)
    app = App(root)
    try:
        assert app.ready['profile'] == original_profile and app.capability != old_cap
        assert app.http('/tasks', headers={'Authorization': 'Bearer ' + old_cap})[0] == 403
        assert app.http('/assistant/messages', request)[0] == 503
        app.grant(request)
        assert app.send(request) == first and len(app.rows()) == 8
        assert len(app.tasks()) == 1
        assert app.http('/assistant/messages?conversation_id=' + request['conversation_id'])[1] == transcript
        assert app.control('authorize', binding={'subject': request['message_id'], 'assistant': uid(), 'conversation': uid(), 'role': 'worker', 'mode': 'assistant'})['op'] == 'refused'
    finally:
        app.close()


@pytest.mark.parametrize('loss', ['cancel', 'app', 'runtime'])
def test_active_worker_loss_preserves_identity_without_duplicate_effect(tmp_path, loss):
    root = tmp_path / 'experiment'
    app = App(root)
    request = body()
    try:
        app.grant(request)
        first = app.send(request)
        task = first['task_ids'][0]
        app.approve(request, task)
        wait_for(app.rows, lambda rows: any(row['status'] == 'reserved' for row in rows))
        children = descendants(app.process.pid)
        assert app.ready['pid'] in children and len(children) >= 2
        if loss == 'cancel':
            assert app.http('/tasks/' + task + '/cancel', {})[0] == 200
            wait_for(lambda: app.task(task), lambda item: item['state'] == 'canceled')
            wait_for(app.rows, lambda rows: any(row['status'] == 'uncertain' for row in rows))
        else:
            os.kill(app.process.pid if loss == 'app' else app.ready['pid'], signal.SIGKILL)
        app.close()
        for pid in children:
            wait_for(lambda: gone(pid), bool)
        app = App(root)
        tasks = app.tasks()
        assert len(tasks) == 1 and tasks[0]['id'] == task
        expected = 'canceled' if loss == 'cancel' else 'needs_decision'
        wait_for(lambda: app.task(task), lambda item: item['state'] == expected)
        assert len(app.rows()) == 3
        assert app.rows()[-1]['status'] == 'uncertain'
        with sqlite3.connect(root / 'runtime/assistant.sqlite') as db:
            assert db.execute('SELECT COUNT(*) FROM effects').fetchone()[0] == 0
            assert db.execute('SELECT COUNT(*) FROM deliveries').fetchone()[0] <= 1
        app.grant(request)
        assert app.send(request) == first and len(app.rows()) == 3
        fresh = body('fresh status', assistant_id=request['assistant_id'], conversation_id=request['conversation_id'])
        app.grant(fresh)
        assert app.http('/assistant/messages', fresh)[0] == 503
        assert len(app.rows()) == 3
    finally:
        app.close()
