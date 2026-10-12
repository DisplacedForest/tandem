import json
import os
from pathlib import Path
import select
import signal
import sqlite3
import subprocess
import sys
import time
import uuid

from test_app_broker import descendants, gone, wait_for
from test_candidate import BINARY, REPO, arguments


def read_report(process: subprocess.Popen, timeout: float = 35) -> dict:
    data = bytearray()
    deadline = time.monotonic() + timeout
    while b'\n' not in data:
        assert time.monotonic() < deadline, 'Native task stream fixture report timed out'
        if select.select([process.stdout], [], [], .1)[0]:
            chunk = os.read(process.stdout.fileno(), 8192)
            if not chunk:
                _, error = process.communicate(timeout=3)
                raise AssertionError('Native task stream fixture closed before reporting: ' + error[:2048].decode(errors='replace'))
            data.extend(chunk)
            assert len(data) <= 65536
    return json.loads(data.partition(b'\n')[0])


def test_native_task_stream_survives_owner_crash_and_reopen(tmp_path: Path) -> None:
    sys.path.insert(0, str(REPO / 'services/vera-api'))
    from routers.task_store import TaskStore

    root = tmp_path / 'native-task-stream'
    home = tmp_path / 'home'
    home.mkdir(mode=0o700)
    environment = {'PATH': '/usr/bin:/bin', 'LANG': 'C.UTF-8', 'HOME': str(home),
                   'CFFIXED_USER_HOME': str(home), 'VERA_CONFIG_DIR': str(home / '.vera')}
    process = subprocess.Popen([str(BINARY), '--pi-task-stream-contract', '--hold', *arguments(root)],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True,
                               env=environment)
    children: set[int] = set()
    try:
        report = read_report(process)
        assert report['event_only_completion'] and report['cursor_reconnect']
        assert report['idle_snapshot_polling'] is False
        assert report['duplicate_cards'] == 0 and report['result_deliveries'] == 1
        assert report['real_provider_calls'] == report['real_keychain_reads'] == 0
        assert report['visible_launch'] is False
        assert len(report['task_ids']) == len(report['card_anchors']) == 3
        artifact = Path(report['artifact_path']).resolve(strict=True)
        assert artifact.is_relative_to((root / 'model/runtime/workspaces').resolve())
        assert artifact.read_text() == 'def add(a, b):\n    return a + b\n'
        store = TaskStore(str(root / 'model/runtime/tasks.sqlite'))
        events = store.events(0, limit=200)
        assert [event['id'] for event in events] == report['event_ids']
        assert report['saved_cursor'] == events[-1]['id']
        assert json.loads((root / 'ui/assistant-ui.json').read_text())['taskEventCursor'] == report['saved_cursor']
        snapshots = {identifier: store.get(identifier) for identifier in report['task_ids']}
        children = descendants(process.pid)
        assert children
        os.killpg(process.pid, signal.SIGKILL)
        process.communicate(timeout=8)
        assert process.returncode == -signal.SIGKILL
        wait_for(lambda: all(gone(pid) for pid in children), bool, timeout=8)
        assert {identifier: store.get(identifier) for identifier in report['task_ids']} == snapshots
        foreign = store.create('pi_worker', {'assistant_id': str(uuid.uuid4()), 'conversation_id': str(uuid.uuid4()),
                                            'originating_message_id': str(uuid.uuid4()), 'objective': 'Foreign fixture',
                                            'workspace_ref': 'task-private', 'transport': 'mock'}, 'foreign-authority')
        foreign = store.cancel(foreign['id'])
        report['foreign_task_id'] = foreign['id']
        (root / 'task-stream-fixture.json').write_text(json.dumps(report))
        restarted = subprocess.run([str(BINARY), '--pi-task-stream-contract', '--reopen', *arguments(root)],
                                   capture_output=True, text=True, timeout=25, env=environment)
        assert restarted.returncode == 0, restarted.stderr
        reopened = json.loads(restarted.stdout)
        for field in ('assistant_id', 'conversation_id', 'task_ids', 'projected_ids', 'card_anchors', 'artifact_path'):
            assert reopened[field] == report[field]
        assert reopened['reopened'] and reopened['foreign_authority_refused']
        assert reopened['fresh_model_calls'] == 0
        assert reopened['saved_cursor'] >= report['saved_cursor']
        assert reopened['reopened_request_cursor'] == report['saved_cursor']
        assert {identifier: store.get(identifier) for identifier in report['task_ids']} == snapshots
        assert store.get(foreign['id']) == foreign
        with sqlite3.connect(root / 'model/runtime/assistant.sqlite') as db:
            assert db.execute('SELECT COUNT(*) FROM effects').fetchone()[0] == 1
    finally:
        if process.poll() is None:
            children |= descendants(process.pid)
            os.killpg(process.pid, signal.SIGKILL)
            process.communicate(timeout=8)
        for pid in children:
            if not gone(pid):
                try:
                    os.kill(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
