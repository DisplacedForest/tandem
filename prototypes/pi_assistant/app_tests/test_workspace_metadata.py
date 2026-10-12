import json
import os
from pathlib import Path
import select
import shutil
import signal
import subprocess
import sys
import time
import uuid

import pytest

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / 'prototypes'))
from pi_assistant import app_bridge


def fixture_file(root: Path, relative: str, mode: int = 0o644) -> Path:
    file = root / relative
    file.parent.mkdir(parents=True, exist_ok=True)
    for directory in (root, *file.parents):
        if directory == root or root in directory.parents:
            directory.chmod(0o700)
    file.write_bytes(b'fixture desktop metadata')
    file.chmod(mode)
    return file


def ready(root: Path) -> None:
    node = shutil.which('node')
    assert node is not None
    process = subprocess.Popen([sys.executable, '-I', '-B', str(REPO / 'prototypes/pi_assistant/app_bridge.py'), '--app-owned'],
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               cwd=root.parent, start_new_session=True,
                               env={'PATH': '/usr/bin:/bin', 'HOME': str(root.parent), 'LANG': 'C.UTF-8'})
    try:
        boot = {'op': 'initialize', 'transport': 'app-owned-mock', 'channel': str(uuid.uuid4()),
                'profile': str(uuid.uuid4()), 'ui_capability': str(uuid.uuid4()) + str(uuid.uuid4()),
                'root': str(root.resolve()), 'node': node, 'port': 0, 'request_timeout': 3}
        process.stdin.write(json.dumps(boot).encode() + b'\n')
        process.stdin.flush()
        data = bytearray()
        deadline = time.monotonic() + 8
        while b'\n' not in data:
            assert time.monotonic() < deadline, 'Disposable runtime startup timed out'
            if select.select([process.stdout], [], [], .1)[0]:
                chunk = os.read(process.stdout.fileno(), 4096)
                assert chunk, 'Disposable runtime refused workspace metadata'
                data.extend(chunk)
                assert len(data) <= 65536
        message = json.loads(data.partition(b'\n')[0])
        assert message['op'] == 'ready' and message['channel'] == boot['channel']
        process.stdin.close()
        process.stdin = None
        _, error = process.communicate(timeout=5)
        assert process.returncode == 0, error
    finally:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGKILL)
            process.communicate(timeout=5)


def test_runtime_restarts_after_finder_creates_workspace_metadata(tmp_path: Path) -> None:
    root = tmp_path / 'runtime'
    ready(root)
    metadata = fixture_file(root, 'workspaces/.DS_Store')
    nested = fixture_file(root, 'workspaces/task/.DS_Store')
    artifact = fixture_file(root, 'workspaces/task/sum.py', 0o600)
    original = {file: (file.read_bytes(), file.stat().st_mode) for file in (metadata, nested, artifact)}
    ready(root)
    assert {file: (file.read_bytes(), file.stat().st_mode) for file in original} == original


@pytest.mark.parametrize('relative', ['.DS_Store', 'accounting/.DS_Store', 'workspaces-other/.DS_Store',
                                     'workspaces/task/sum.py', 'workspaces/task/.DS_Store.bak', 'tasks.sqlite'])
def test_public_permissions_remain_forbidden_outside_exact_workspace_metadata(tmp_path: Path, relative: str) -> None:
    root = tmp_path / 'runtime'
    fixture_file(root, relative)
    with pytest.raises(ValueError, match='private runtime required'):
        app_bridge.validate_runtime_files(root)


@pytest.mark.parametrize('mode', [0o664, 0o646, 0o654, 0o645, 0o666, 0o744, 0o777])
def test_workspace_metadata_cannot_grant_write_or_execute_to_others(tmp_path: Path, mode: int) -> None:
    root = tmp_path / 'runtime'
    fixture_file(root, 'workspaces/.DS_Store', mode)
    with pytest.raises(ValueError, match='private runtime required'):
        app_bridge.validate_runtime_files(root)


@pytest.mark.parametrize('kind', ['symlink', 'hardlink', 'directory', 'fifo', 'parent_symlink'])
def test_workspace_metadata_preserves_type_and_link_boundaries(tmp_path: Path, kind: str) -> None:
    root = tmp_path / 'runtime'
    target = fixture_file(root, 'workspaces/.DS_Store', 0o600)
    if kind == 'hardlink':
        os.link(target, tmp_path / 'linked')
    else:
        target.unlink()
        if kind == 'symlink':
            source = fixture_file(tmp_path / 'outside', '.DS_Store', 0o600)
            target.symlink_to(source)
        elif kind == 'directory':
            target.mkdir(mode=0o700)
        elif kind == 'fifo':
            os.mkfifo(target, 0o600)
        else:
            target.parent.rmdir()
            outside = tmp_path / 'outside'
            outside.mkdir(mode=0o700)
            target.parent.symlink_to(outside, target_is_directory=True)
    with pytest.raises(ValueError, match='private runtime required'):
        app_bridge.validate_runtime_files(root)


def test_workspace_metadata_must_remain_owned_by_runtime_user(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    root = tmp_path / 'runtime'
    metadata = fixture_file(root, 'workspaces/.DS_Store')
    original = Path.lstat

    def other_owner(file: Path) -> os.stat_result:
        info = original(file)
        if file == metadata:
            changed = list(info)
            changed[4] = os.getuid() + 1
            return os.stat_result(changed)
        return info

    monkeypatch.setattr(Path, 'lstat', other_owner)
    with pytest.raises(ValueError, match='private runtime required'):
        app_bridge.validate_runtime_files(root)
