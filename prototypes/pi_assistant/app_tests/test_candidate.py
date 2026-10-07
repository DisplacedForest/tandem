import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[3]
BINARY = REPO / 'apps/vera-mac/.build/debug/Vera'


def arguments(root: Path, repo: Path = REPO) -> list[str]:
    return ['--root', str(root.resolve()), '--repo', str(repo), '--python', sys.executable, '--node', shutil.which('node'), '--port', '0']


def run(mode: str, args: list[str], timeout: int = 30) -> subprocess.CompletedProcess:
    return subprocess.run([str(BINARY), mode, *args], capture_output=True, text=True, timeout=timeout, env={'PATH': '/usr/bin:/bin', 'LANG': 'C.UTF-8'})


@pytest.mark.parametrize('flag', ['--pi-candidate-live', '--pi-candidate-typo', '--pi-unknown'])
def test_unknown_mode_refuses(flag: str) -> None:
    result = run(flag, [])
    assert result.returncode == 2
    assert result.stderr == 'Unsupported isolated Vera mode\n'


def test_nonregular_profile_refuses(tmp_path: Path) -> None:
    root = tmp_path / 'candidate'
    root.mkdir(mode=0o700)
    os.mkfifo(root / 'profile.json', 0o600)
    result = run('--pi-candidate-contract', arguments(root), timeout=3)
    assert result.returncode == 1
    assert not (root / 'model').exists()


def test_candidate_approval_and_profile_boundaries(tmp_path: Path) -> None:
    result = run('--pi-candidate-selftest', arguments(tmp_path / 'candidate'))
    assert result.returncode == 0, result.stderr
    assert 'PASS:' in result.stdout


def test_candidate_store_workflow(tmp_path: Path) -> None:
    root = tmp_path / 'candidate'
    result = run('--pi-candidate-contract', arguments(root))
    assert result.returncode == 0, result.stderr
    report = json.loads(result.stdout)
    assert report['real_keychain_reads'] == report['real_provider_calls'] == report['installed_changes'] == 0
    assert report['provider_fixture_calls'] == 10
    assert report['credential_reads'] == 2
    assert report['admission']['active'] == 0
    assert report['workflow']['foreground_while_worker_active']
    assert report['workflow']['focused_no_delegation']
    assert report['workflow']['result_deliveries'] == 1
    assert Path(report['workflow']['artifact_path']).is_file()


def test_missing_scope_ack_is_bounded(tmp_path: Path) -> None:
    repo = tmp_path / 'checkout'
    source = repo / 'prototypes/pi_assistant'
    source.mkdir(parents=True)
    for name in ('app_model.py', 'runtime.py', 'bridge.py', 'process.py', 'agent.mjs', 'package-lock.json', 'native.py'):
        shutil.copyfile(REPO / 'prototypes/pi_assistant' / name, source / name)
    (source / 'app_bridge.py').write_text('import json,os,sys\nif os.getpgrp()!=os.getpid(): os.setsid()\nboot=json.loads(sys.stdin.readline())\nprint(json.dumps({"op":"ready","channel":boot["channel"],"port":54321}),flush=True)\nfor line in sys.stdin: pass\n')
    result = run('--pi-candidate-selftest', ['--scope-timeout', *arguments(tmp_path / 'candidate', repo)], timeout=12)
    assert result.returncode == 0, result.stderr


def test_candidate_sigkill_preserves_identity_and_uncertain_usage(tmp_path: Path) -> None:
    import signal
    import sqlite3
    import time
    from test_app_broker import descendants, gone, wait_for

    root = tmp_path / 'candidate'
    process = subprocess.Popen([str(BINARY), '--pi-candidate-contract', *arguments(root)], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    state_file = root / 'ui/assistant-ui.json'
    ledger = root / 'model/broker.sqlite'
    journal = root / 'model/runtime/assistant.sqlite'
    children: set[int] = set()
    try:
        until = time.monotonic() + 15
        original = None
        while time.monotonic() < until and process.poll() is None:
            try:
                state = json.loads(state_file.read_text())
                if not state['pending']:
                    continue
                with sqlite3.connect(f'file:{ledger}?mode=ro', uri=True) as db:
                    active = db.execute("SELECT COUNT(*) FROM requests WHERE status='reserved'").fetchone()[0]
                with sqlite3.connect(f'file:{journal}?mode=ro', uri=True) as db:
                    turns = db.execute("SELECT COUNT(*) FROM turns WHERE state='running'").fetchone()[0]
                with sqlite3.connect(f'file:{root / "model/runtime/tasks.sqlite"}?mode=ro', uri=True) as db:
                    delegated = db.execute('SELECT COUNT(*) FROM tasks').fetchone()[0]
                if active >= 2 and turns == 1 and delegated == 1:
                    original = state
                    children = descendants(process.pid)
                    process.kill()
                    break
            except (OSError, KeyError, sqlite3.Error, json.JSONDecodeError):
                pass
            time.sleep(.002)
        assert original is not None, 'Did not observe concurrent worker and pending foreground before kill'
        process.communicate(timeout=8)
        wait_for(lambda: all(gone(pid) for pid in children), bool, timeout=8)
        result = run('--pi-candidate-recovery-contract', arguments(root))
        assert result.returncode == 0, result.stderr
        report = json.loads(result.stdout)
        assert report['assistant_id'] == original['assistantID'].lower()
        assert report['archived_message_id'] == original['pending'][0]['message_id'].lower()
        assert report['tasks_unchanged'] and report['archived_on_reopen']
        assert report['fresh_send_attempted'] is False
        for directory in ('accounting', 'model'):
            with sqlite3.connect(root / directory / 'broker.sqlite') as db:
                rows = db.execute("SELECT reserved,charged FROM requests WHERE status='uncertain'").fetchall()
                assert rows and all(reserved == 1000000 and charged is None for reserved, charged in rows)
        with sqlite3.connect(root / 'model/runtime/tasks.sqlite') as db:
            tasks = db.execute('SELECT id,state FROM tasks').fetchall()
            assert len(tasks) == 1 and tasks[0][0] in report['original_task_ids']
            assert tasks[0][1] == 'needs_decision'
        with sqlite3.connect(journal) as db:
            assert db.execute('SELECT COUNT(*) FROM effects').fetchone()[0] == 0
    finally:
        if process.poll() is None:
            process.kill()
            process.communicate(timeout=8)
        for pid in children:
            if not gone(pid):
                try:
                    os.kill(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
