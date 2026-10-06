import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import time
import urllib.request
import uuid
from pathlib import Path


REPO = Path(__file__).resolve().parents[3]


def start(root: Path, host: str = '127.0.0.1', listening: bool = True) -> tuple[subprocess.Popen, socket.socket, str]:
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM if listening else socket.SOCK_DGRAM)
    listener.bind((host, 0))
    if listening:
        listener.listen()
    identity = str(uuid.uuid4())
    env = {'PATH': os.path.dirname(shutil.which('node')) + ':/usr/bin:/bin', 'LANG': 'C.UTF-8', 'PYTHONDONTWRITEBYTECODE': '1'}
    command = [sys.executable, str(REPO / 'prototypes/pi_assistant/bridge.py'), '--data-root', str(root), '--port', str(listener.getsockname()[1]), '--listen-fd', str(listener.fileno()), '--supervised', '--instance-id', identity]
    process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, pass_fds=(listener.fileno(),), env=env, start_new_session=True)
    return process, listener, identity


def stop(process: subprocess.Popen, listener: socket.socket) -> None:
    if process.stdin:
        process.stdin.close()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait(timeout=3)
    listener.close()


def test_inherited_socket_identity_and_parent_eof(tmp_path: Path) -> None:
    root = tmp_path / 'runtime'
    process, listener, identity = start(root)
    try:
        endpoint = 'http://127.0.0.1:' + str(listener.getsockname()[1])
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        for _ in range(100):
            assert process.poll() is None
            try:
                with opener.open(endpoint + '/assistant/capabilities', timeout=.2) as response:
                    value = json.load(response)
                break
            except OSError:
                time.sleep(.03)
        else:
            raise AssertionError('Bridge did not start')
        assert value['instance_id'] == identity and value['transport'] == 'mock'
        assert Path(value['workspace_root']) == root.resolve() / 'workspaces'
        process.stdin.close()
        process.wait(timeout=5)
        assert process.returncode == 0
    finally:
        stop(process, listener)


def test_parent_eof_during_startup_still_stops(tmp_path: Path) -> None:
    process, listener, _ = start(tmp_path / 'runtime')
    try:
        process.stdin.close()
        process.wait(timeout=5)
        assert process.returncode == 0
    finally:
        stop(process, listener)


def test_supervision_rejects_nonloopback_and_datagram_socket(tmp_path: Path) -> None:
    for index, (host, listening) in enumerate([('0.0.0.0', True), ('127.0.0.1', False)]):
        root = tmp_path / str(index)
        process, listener, _ = start(root, host, listening)
        try:
            process.wait(timeout=5)
            assert process.returncode != 0
            assert not root.exists()
        finally:
            stop(process, listener)
