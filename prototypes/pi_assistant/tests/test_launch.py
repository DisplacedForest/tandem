import json
import os
import socket
import sqlite3
import stat
import signal
import threading
import time
import uuid
import subprocess
import sys
from pathlib import Path

import pytest

from pi_assistant.launch import SessionState
from pi_assistant._session_process import _ready, _stop, run_session


REPO = Path(__file__).resolve().parents[3]


def test_session_preserves_identity_and_pins_port(tmp_path: Path) -> None:
    root = tmp_path / 'session'
    with SessionState(root, 48761):
        (root / 'ui/sentinel').write_text('existing identity and draft')
        with pytest.raises(RuntimeError, match='already open'):
            with SessionState(root, 48761):
                pass
    original = (root / 'session.json').read_bytes()
    with SessionState(root, 48761):
        assert (root / 'ui/sentinel').read_text() == 'existing identity and draft'
    with pytest.raises(RuntimeError, match='do not match'):
        with SessionState(root, 48762):
            pass
    assert (root / 'session.json').read_bytes() == original


def test_session_rejects_existing_data_and_unsafe_files(tmp_path: Path) -> None:
    root = tmp_path / 'occupied'
    root.mkdir(mode=0o700)
    (root / 'unrelated').write_text('preserve')
    with pytest.raises(RuntimeError, match='empty directory'):
        with SessionState(root, 48761):
            pass
    assert (root / 'unrelated').read_text() == 'preserve'
    good = tmp_path / 'good'
    with SessionState(good, 48761):
        pass
    alias = tmp_path / 'alias'
    alias.symlink_to(good, target_is_directory=True)
    with pytest.raises(RuntimeError):
        with SessionState(alias, 48761):
            pass
    metadata = good / 'session.json'
    metadata.chmod(0o644)
    with pytest.raises(RuntimeError):
        with SessionState(good, 48761):
            pass
    metadata.chmod(0o600)
    os.link(metadata, tmp_path / 'hardlink')
    with pytest.raises(RuntimeError):
        with SessionState(good, 48761):
            pass
    (tmp_path / 'hardlink').unlink()
    (good / 'runtime').rmdir()
    (good / 'runtime').symlink_to(root, target_is_directory=True)
    with pytest.raises(OSError):
        with SessionState(good, 48761):
            pass
    assert (root / 'unrelated').read_text() == 'preserve'


def test_launcher_busy_port_never_starts_ui(tmp_path: Path) -> None:
    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 0))
        listener.listen()
        port = listener.getsockname()[1]
        root = tmp_path / 'session'
        result = subprocess.run([sys.executable, str(REPO / 'prototypes/pi_assistant/launch.py'), '--mock', '--contract-test', '--data-root', str(root), '--port', str(port)], capture_output=True, text=True, timeout=5)
        assert result.returncode == 1 and 'busy' in result.stderr
        assert not (root / 'ui/assistant-ui.json').exists()
        assert not (root / 'runtime/tasks.sqlite').exists()


def test_launcher_actual_headless_ui_and_clean_shutdown(tmp_path: Path) -> None:
    with socket.socket() as probe:
        probe.bind(('127.0.0.1', 0))
        port = probe.getsockname()[1]
    root = tmp_path / 'session'
    result = subprocess.run([sys.executable, str(REPO / 'prototypes/pi_assistant/launch.py'), '--mock', '--contract-test', '--data-root', str(root), '--port', str(port)], capture_output=True, text=True, timeout=25)
    assert result.returncode == 0, result.stdout + result.stderr
    assert 'actual mock bridge HTTP' in result.stdout
    saved = json.loads((root / 'ui/assistant-ui.json').read_bytes())
    assert saved['assistantID']
    with sqlite3.connect(root / 'runtime/tasks.sqlite') as db:
        states = [row[0] for row in db.execute('SELECT state FROM tasks ORDER BY created_at')]
        assert sorted(states) == ['canceled', 'completed']
    assert list((root / 'runtime/workspaces').glob('*/sum.py'))
    with socket.socket() as probe:
        probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        probe.bind(('127.0.0.1', port))
    before = (root / 'ui/assistant-ui.json').read_bytes()
    with SessionState(root, port):
        assert (root / 'ui/assistant-ui.json').read_bytes() == before
    assert stat.S_IMODE(root.stat().st_mode) == 0o700


@pytest.mark.parametrize('name', ['session.lock', 'session.json'])
def test_session_rejects_fifo_before_reading(tmp_path: Path, name: str) -> None:
    root = tmp_path / 'session'
    root.mkdir(mode=0o700)
    os.mkfifo(root / name, 0o600)
    started = time.monotonic()
    with pytest.raises(RuntimeError):
        with SessionState(root, 48761):
            pass
    assert time.monotonic() - started < .5


def test_readiness_rejects_slow_headers_with_total_deadline() -> None:
    listener = socket.socket()
    listener.bind(('127.0.0.1', 0))
    listener.listen()
    port = listener.getsockname()[1]
    stop = threading.Event()
    def trickle() -> None:
        with listener:
            connection, _ = listener.accept()
            with connection:
                connection.recv(4096)
                for byte in b'HTTP/1.1 200 OK':
                    if stop.wait(.08):
                        break
                    try:
                        connection.sendall(bytes([byte]))
                    except OSError:
                        break
    thread = threading.Thread(target=trickle)
    thread.start()
    started = time.monotonic()
    try:
        assert not _ready(port, 'fixture', '/fixture')
        assert time.monotonic() - started < .8
    finally:
        stop.set()
        thread.join(timeout=2)
    assert not thread.is_alive()


def test_cleanup_kills_descendant_after_leader_exit(tmp_path: Path) -> None:
    marker = tmp_path / 'descendant'
    child = "import os,signal,time;from pathlib import Path;signal.signal(signal.SIGTERM,signal.SIG_IGN);Path(%r).write_text(str(os.getpid()));time.sleep(60)" % str(marker)
    parent = "import subprocess,sys,time;from pathlib import Path;subprocess.Popen([sys.executable,'-c',%r]);p=Path(%r);\nwhile not p.exists():time.sleep(.01)" % (child, str(marker))
    process = subprocess.Popen([sys.executable, '-c', parent], start_new_session=True)
    try:
        process.wait(timeout=3)
        assert marker.exists()
        _stop(process, False)
        with pytest.raises(ProcessLookupError):
            os.killpg(process.pid, 0)
    finally:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait(timeout=2)


def test_launcher_death_keeps_ui_lease_and_stops_bridge(tmp_path: Path) -> None:
    with socket.socket() as probe:
        probe.bind(('127.0.0.1', 0))
        port = probe.getsockname()[1]
    root = tmp_path / 'session'
    marker = tmp_path / 'ui-ready'
    program = """
import os,socket,sys,uuid
from pathlib import Path
from pi_assistant.launch import SessionState
from pi_assistant._session_process import run_session
root=Path(sys.argv[1]);port=int(sys.argv[2]);repo=Path(sys.argv[3]);marker=sys.argv[4]
with SessionState(root,port) as state:
 listener=socket.socket();listener.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1);listener.bind(('127.0.0.1',port));listener.listen()
 identity=str(uuid.uuid4())
 bridge=[sys.executable,str(repo/'prototypes/pi_assistant/bridge.py'),'--data-root',str(root/'runtime'),'--port',str(port),'--listen-fd',str(listener.fileno()),'--supervised','--instance-id',identity]
 ui=[sys.executable,'-c',"import os,time;from pathlib import Path;Path("+repr(marker)+").write_text(str(os.getpid()));time.sleep(60)"]
 run_session(bridge,ui,listener,identity,root/'runtime/workspaces',{'PATH':os.environ['PATH'],'LANG':'C.UTF-8','PYTHONDONTWRITEBYTECODE':'1'},lease_fd=state.lock)
"""
    process = subprocess.Popen([sys.executable, '-c', program, str(root), str(port), str(REPO), str(marker)], start_new_session=True)
    ui_pid = None
    try:
        for _ in range(300):
            if marker.exists():
                ui_pid = int(marker.read_text())
                break
            assert process.poll() is None
            time.sleep(.02)
        assert ui_pid is not None
        process.kill()
        process.wait(timeout=3)
        with pytest.raises(RuntimeError, match='already open'):
            with SessionState(root, port):
                pass
        for _ in range(200):
            with socket.socket() as probe:
                probe.settimeout(.1)
                if probe.connect_ex(('127.0.0.1', port)) != 0:
                    break
            time.sleep(.02)
        else:
            raise AssertionError('Bridge survived its parent pipe closing')
        os.killpg(ui_pid, signal.SIGTERM)
        for _ in range(200):
            try:
                with SessionState(root, port):
                    break
            except RuntimeError:
                time.sleep(.02)
        else:
            raise AssertionError('UI lease survived UI exit')
    finally:
        if process.poll() is None:
            process.kill()
        process.wait(timeout=3)
        if ui_pid:
            try:
                os.killpg(ui_pid, signal.SIGKILL)
            except ProcessLookupError:
                pass


def test_cleanup_darwin_retries_zombie_group_probe(monkeypatch):
    from pi_assistant import _session_process as session_process
    from unittest.mock import Mock
    process = Mock(pid=43210, stdin=None)
    operations = []
    def killpg(pid, sig):
        assert pid == process.pid
        operations.append(sig)
        if len(operations) == 2:
            raise PermissionError()
        if len(operations) == 3:
            raise ProcessLookupError()
    monkeypatch.setattr(session_process.sys, 'platform', 'darwin')
    monkeypatch.setattr(session_process.os, 'killpg', killpg)
    _stop(process, False)
    assert operations == [signal.SIGTERM, 0, 0]
    process.wait.assert_called_once_with(2.0)


def test_cleanup_does_not_ignore_signal_permission_failure(monkeypatch):
    from pi_assistant import _session_process as session_process
    from unittest.mock import Mock
    process = Mock(pid=43210, stdin=None)
    def denied(pid, sig):
        raise PermissionError()
    monkeypatch.setattr(session_process.os, 'killpg', denied)
    with pytest.raises(PermissionError):
        _stop(process, False)
    process.wait.assert_not_called()


def test_cleanup_darwin_persistent_probe_denial_preserves_session(monkeypatch):
    from pi_assistant import _session_process as session_process
    from unittest.mock import Mock
    process = Mock(pid=43210, stdin=None)
    operations = []
    def killpg(pid, sig):
        operations.append(sig)
        if sig == 0:
            raise PermissionError()
    clock = iter([0.0, 0.1, 2.1])
    monkeypatch.setattr(session_process.sys, 'platform', 'darwin')
    monkeypatch.setattr(session_process.os, 'killpg', killpg)
    monkeypatch.setattr(session_process.time, 'monotonic', lambda: next(clock))
    with pytest.raises(PermissionError, match='preserve this session'):
        _stop(process, False)
    assert operations == [signal.SIGTERM, 0]
    process.wait.assert_not_called()
