import json
import os
import shutil
import sqlite3
import subprocess
import sys
import time
from pathlib import Path

import pytest

from test_app_broker import App, REPO, body, gone, wait_for


RUNTIME = '''import json,os,signal,subprocess,sys,time,uuid
from pathlib import Path
boot=json.loads(sys.stdin.readline())
root=Path(boot['root']);root.mkdir(parents=True,exist_ok=True,mode=0o700)
if os.getpgrp()!=os.getpid():os.setsid()
def send(value):
 print(json.dumps(value),flush=True)
def receive():
 return json.loads(sys.stdin.readline())
send({'op':'ready','channel':boot['channel'],'port':12345})
mode=MODE
if mode in ['descendant','exited_leader']:
 signal.signal(signal.SIGTERM,signal.SIG_IGN)
 child=subprocess.Popen([sys.executable,'-c','import signal,time;signal.signal(signal.SIGTERM,signal.SIG_IGN);time.sleep(60)'])
 (root/'child.pid').write_text(str(child.pid))
 print('malformed',flush=True)
 if mode=='exited_leader':sys.exit(0)
 time.sleep(60)
elif mode=='authority':
 send({'op':'authorize','id':str(uuid.uuid4()),'binding':{}})
 time.sleep(60)
else:
 scope=receive()['binding']
 send({'op':'scoped','channel':boot['channel'],'scope':scope['scope']})
 request={'op':'complete','id':str(uuid.uuid4()),'channel':boot['channel'],**scope,'messages':[{'role':'user','content':'fixture'}]}
 if mode in ['channel','profile','subject','assistant','conversation','scope','role','mode']:
  request[mode]='wrong'
  send(request)
  result=receive()
  assert result['ok'] is False
 elif mode=='replay':
  send(request);first=receive();assert first['ok'] is True
  send(request);second=receive();assert second==first
 elif mode=='digest':
  send(request);assert receive()['ok'] is True
  request['messages'][0]['content']='changed'
  send(request);assert receive()['ok'] is False
 elif mode=='early_cancel':
  cancel={'op':'cancel','id':request['id'],'channel':boot['channel']}
  sys.stdout.write(json.dumps(cancel)+'\\n'+json.dumps(request)+'\\n');sys.stdout.flush()
  assert receive()['ok'] is False
 elif mode=='coalesced_cancel':
  cancel={'op':'cancel','id':request['id'],'channel':boot['channel']}
  sys.stdout.write(json.dumps(request)+'\\n'+json.dumps(cancel)+'\\n');sys.stdout.flush()
  assert receive()['ok'] is False
 (root/'passed').write_text('passed')
 while sys.stdin.readline():pass
'''


def fake_repo(tmp_path, mode):
    repo = tmp_path / 'repo'
    source = repo / 'prototypes/pi_assistant'
    source.mkdir(parents=True)
    for name in ('app_model.py', 'runtime.py', 'bridge.py', 'process.py', 'agent.mjs', 'package-lock.json', 'native.py'):
        shutil.copyfile(REPO / 'prototypes/pi_assistant' / name, source / name)
    (source / 'app_bridge.py').write_text(RUNTIME.replace('MODE', repr(mode)))
    return repo


@pytest.mark.parametrize('mode', ['channel', 'profile', 'subject', 'assistant', 'conversation', 'scope', 'role', 'mode', 'replay', 'digest', 'early_cancel', 'coalesced_cancel'])
def test_private_channel_validation_and_replay(tmp_path, mode):
    root = tmp_path / 'experiment'
    app = App(root, fake_repo(tmp_path, mode))
    try:
        app.grant(body('fixture'))
        wait_for(lambda: (root / 'runtime/passed').exists(), bool)
        rows = app.rows()
        if mode in {'replay', 'digest'}:
            assert len(rows) == 1 and rows[0]['status'] == 'completed' and rows[0]['charged'] == 28000
        elif mode == 'coalesced_cancel':
            assert not rows or len(rows) == 1 and rows[0]['status'] == 'uncertain'
        else:
            assert rows == []
    finally:
        app.close()


@pytest.mark.parametrize('mode', ['descendant', 'exited_leader', 'authority'])
def test_malicious_child_cannot_authorize_or_hold_app_open(tmp_path, mode):
    root = tmp_path / 'experiment'
    app = App(root, fake_repo(tmp_path, mode))
    child = None
    try:
        if mode in {'descendant', 'exited_leader'}:
            file = root / 'runtime/child.pid'
            wait_for(file.exists, bool)
            child = int(file.read_text())
        app.process.wait(timeout=6)
        assert app.process.returncode == 0
        with sqlite3.connect(root / 'broker.sqlite') as db:
            assert db.execute('SELECT COUNT(*) FROM requests').fetchone()[0] == 0
            assert db.execute('SELECT COUNT(*) FROM bindings').fetchone()[0] == 0
        if child:
            wait_for(lambda: gone(child), bool)
    finally:
        app.close()
        if child and not gone(child):
            os.kill(child, 9)


@pytest.mark.parametrize('column,value', [('reserved', 'invalid-number'), ('reserved', 1e30), ('charged', 'invalid-number'), ('charged', None), ('reply', 'text-instead-of-blob'), ('status', b'completed'), ('digest', b'invalid-digest')])
def test_corrupt_ledger_refuses_without_crashing_app(tmp_path, column, value):
    root = tmp_path / 'experiment'
    repo = fake_repo(tmp_path, 'replay')
    app = App(root, repo)
    try:
        app.grant(body('fixture'))
        wait_for(lambda: (root / 'runtime/passed').exists(), bool)
    finally:
        app.close()
    with sqlite3.connect(root / 'broker.sqlite') as db:
        db.execute('UPDATE requests SET ' + column + '=?', (value,))
    process = subprocess.Popen([str(REPO / 'apps/vera-mac/.build/debug/Vera'), '--pi-broker-mock', '--root', str(root), '--repo', str(repo), '--python', sys.executable, '--node', shutil.which('node'), '--port', '0'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    output, error = process.communicate(timeout=5)
    assert process.returncode == 1 and output == b'' and b'Fatal error' not in error
