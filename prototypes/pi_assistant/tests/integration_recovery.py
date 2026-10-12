import argparse
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--repo', type=Path, default=Path(__file__).resolve().parents[3])
parser.add_argument('--evidence', type=Path)
args = parser.parse_args()
repo = args.repo.resolve()
evidence = args.evidence.resolve() if args.evidence else None
if evidence:
    evidence.mkdir(parents=True, exist_ok=True)
def record_file(name, text):
    if evidence:
        (evidence / name).write_text(text)
with tempfile.TemporaryDirectory(prefix='vera-combined-recovery-') as temporary:
    root = Path(temporary)
    runtime_root = root / 'runtime'
    ui_root = root / 'ui'
    ui_root.mkdir()
    marker = root / 'accepted.json'
    with socket.socket() as probe:
        probe.bind(('127.0.0.1', 0))
        port = probe.getsockname()[1]
    endpoint = f'http://127.0.0.1:{port}'
    request = {key: str(uuid.uuid4()) for key in ('assistant_id', 'conversation_id', 'message_id')}
    request.update(text='/task Preserve this accepted work after interruption', mode='assistant')
    state = {'assistantID': request['assistant_id'], 'assistant': {'id': request['conversation_id'], 'title': 'Vera', 'draft': request['text']}, 'conversations': [], 'pending': [request], 'decisions': {}, 'endpoint': endpoint}
    (ui_root / 'assistant-ui.json').write_text(json.dumps(state))
    launcher = root / 'slow_bridge.py'
    launcher.write_text('''import asyncio,json,shutil,sys
from pathlib import Path
import uvicorn
from pi_assistant.bridge import create_app
app=create_app(Path(sys.argv[1]),shutil.which('node'))
runtime=app.state.runtime
original=runtime.process.run
async def intercept(config,host,canceled=lambda:False):
 async def wrapped(event):
  result=await host(event)
  if config['role']=='foreground' and event.get('name')=='delegate':
   Path(sys.argv[2]).write_text(json.dumps({'task_id':result['task_id'],'worker_pids':list(runtime.process.pids)}))
   await asyncio.Event().wait()
  return result
 return await original(config,wrapped,canceled)
runtime.process.run=intercept
uvicorn.run(app,host='127.0.0.1',port=int(sys.argv[3]),access_log=False,log_level='warning')
''')
    env = {'PATH': os.path.dirname(shutil.which('node')) + ':/usr/bin:/bin', 'LANG': 'C.UTF-8', 'PYTHONPATH': str(repo / 'prototypes') + ':' + str(repo / 'services' / 'vera-api'), 'PYTHONDONTWRITEBYTECODE': '1'}
    def read(path):
        with urllib.request.urlopen(endpoint + path, timeout=2) as response:
            return json.load(response)
    def ready(process):
        for _ in range(100):
            if process.poll() is not None:
                raise AssertionError('Test bridge exited')
            try:
                if read('/assistant/capabilities')['transport'] == 'mock':
                    return
            except (OSError, urllib.error.URLError):
                time.sleep(.05)
        raise AssertionError('Test bridge unavailable')
    process = subprocess.Popen([sys.executable, str(launcher), str(runtime_root), str(marker), str(port)], cwd=repo, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    restarted = None
    def send():
        try:
            req = urllib.request.Request(endpoint + '/assistant/messages', data=json.dumps(request).encode(), headers={'Content-Type': 'application/json'})
            urllib.request.urlopen(req, timeout=10).read()
        except (OSError, urllib.error.URLError):
            pass
    try:
        ready(process)
        sending = threading.Thread(target=send)
        sending.start()
        for _ in range(150):
            if marker.exists():
                break
            time.sleep(.02)
        assert marker.exists(), 'Task was not durably accepted'
        accepted = json.loads(marker.read_text())
        process.kill()
        process.wait(timeout=3)
        sending.join(timeout=3)
        restarted = subprocess.Popen([sys.executable, str(repo / 'prototypes/pi_assistant/bridge.py'), '--data-root', str(runtime_root), '--port', str(port)], cwd=repo, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        ready(restarted)
        before = read('/tasks')['tasks']
        assert len(before) == 1 and before[0]['id'] == accepted['task_id']
        binary = repo / 'prototypes/assistant-ui/.build/debug/VeraPrototype'
        run = subprocess.run([str(binary), '--recovery-contract-test', '--data-root', str(ui_root), '--endpoint', endpoint, '--workspace-root', str(runtime_root / 'workspaces')], cwd=repo, text=True, capture_output=True, timeout=15)
        record_file('integrated-recovery-consumer.log', run.stdout + run.stderr)
        assert run.returncode == 0, run.stdout + run.stderr
        after = read('/tasks')['tasks']
        assert len(after) == 1 and after[0]['id'] == accepted['task_id']
        assert after[0]['state'] in {'queued', 'needs_decision'}
        regular = subprocess.run([str(binary), '--contract-test', '--data-root', str(root / 'regular-ui'), '--endpoint', endpoint, '--workspace-root', str(runtime_root / 'workspaces')], cwd=repo, text=True, capture_output=True, timeout=15)
        record_file('integrated-http-consumer.log', regular.stdout + regular.stderr)
        assert regular.returncode == 0, regular.stdout + regular.stderr
        final_tasks = read('/tasks')['tasks']
        assert len(final_tasks) == 3
        assert sum(item['id'] == accepted['task_id'] for item in final_tasks) == 1
        assert sorted(item['state'] for item in final_tasks if item['id'] != accepted['task_id']) == ['canceled', 'completed']
        record = {'result': 'passed', 'real_bridge_sigkill': True, 'kill_boundary': 'durable foreground turn and child task accepted before parent reply', 'task_id_preserved': True, 'recovery_task_count': 1, 'regular_consumer_task_count': 2, 'automatic_resubmissions': 0, 'foreground_recovery': 'explicit native review and abandon, then explicit fresh Send', 'transport': 'mock', 'paid_calls': 0, 'gui_launches': 0}
        record_file('integrated-recovery.json', json.dumps(record, indent=2) + '\n')
        print(regular.stdout.strip())
        print(run.stdout.strip())
        print('PASS: real bridge SIGKILL preserved one task; reopened native consumer recovered without resubmission')
    finally:
        for item in (process, restarted):
            if item is not None and item.poll() is None:
                item.terminate()
                try:
                    item.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    item.kill()
                    item.wait(timeout=3)
