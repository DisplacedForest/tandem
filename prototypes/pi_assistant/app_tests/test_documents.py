import json
import os
from pathlib import Path
import signal
import subprocess

import pytest

from test_app_broker import descendants, gone, wait_for
from test_candidate import BINARY, arguments
from test_task_stream import read_report


def run(mode, root, timeout=35):
    result = subprocess.run([str(BINARY), '--pi-document-contract', mode, *arguments(root)],
                            capture_output=True, text=True, timeout=timeout,
                            env={'PATH': '/usr/bin:/bin', 'LANG': 'C.UTF-8'})
    assert result.returncode == 0, result.stderr
    return json.loads(result.stdout)


def test_native_document_completion_and_reopen(tmp_path):
    root = tmp_path / 'document'
    report = run('complete', root)
    assert report['state'] == 'completed' and report['artifacts'] == 1
    assert report['fixture_calls'] == 12
    assert report['real_provider_calls'] == report['real_keychain_reads'] == 0
    reopened = run('reopen', root)
    for key in ('task_id', 'conversation_id', 'projected_ids', 'artifacts'):
        assert report[key] == reopened[key]
    assert reopened['fixture_calls'] == 0


def test_native_document_cancel(tmp_path):
    report = run('cancel', tmp_path / 'cancel')
    assert report['state'] == 'canceled' and report['artifacts'] == 0


def test_native_document_sigkill_draft_retry(tmp_path: Path):
    root = tmp_path / 'recovery'
    process = subprocess.Popen([str(BINARY), '--pi-document-contract', 'hold-draft', *arguments(root)],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True,
                               env={'PATH': '/usr/bin:/bin', 'LANG': 'C.UTF-8'})
    children = set()
    try:
        initial = read_report(process)
        assert initial['draft_progress']
        children = descendants(process.pid)
        os.killpg(process.pid, signal.SIGKILL)
        process.communicate(timeout=8)
        wait_for(lambda: all(gone(pid) for pid in children), bool, timeout=8)
        result = run('retry', root)
        assert result['task_id'] == initial['task_id']
        assert result['state'] == 'completed' and result['artifacts'] == 1
        assert result['fixture_calls'] <= 8
    finally:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGKILL)
            process.communicate(timeout=8)


def test_conversation_document_handoff_precedes_slow_acknowledgment(tmp_path):
    report = run('delayed', tmp_path / 'delayed')
    assert report['state'] == 'completed' and report['artifacts'] == 1
    assert report['fixture_calls'] == 11
    assert report['real_provider_calls'] == report['real_keychain_reads'] == 0


@pytest.mark.parametrize('mode', ['foreign-origin', 'foreign-conversation', 'foreign-task', 'foreign-assistant', 'foreign-worker'])
def test_conversation_document_rejects_foreign_handoff(tmp_path, mode):
    report = run(mode, tmp_path / mode)
    assert report['state'] == 'needs_decision' and report['artifacts'] == 0
    assert report['fixture_calls'] == 2
    assert report['real_provider_calls'] == report['real_keychain_reads'] == 0
