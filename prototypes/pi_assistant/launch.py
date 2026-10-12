import argparse
import fcntl
import json
import os
import socket
import stat
import sys
import uuid
from pathlib import Path
from types import TracebackType

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from pi_assistant._session_process import run_session


class SessionState:
    def __init__(self, root: Path, port: int):
        self.root = root.expanduser().absolute()
        self.port = port
        self.directory = -1
        self.lock = -1

    @staticmethod
    def secure(descriptor: int, directory: bool = False) -> None:
        info = os.fstat(descriptor)
        kind = stat.S_ISDIR(info.st_mode) if directory else stat.S_ISREG(info.st_mode) and info.st_nlink == 1
        if not kind or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise RuntimeError('Session files must be private and owned by you')

    def __enter__(self) -> 'SessionState':
        live = Path.home().resolve() / '.vera'
        if not 1 <= self.port <= 65535 or self.root.resolve() != self.root or self.root == live or self.root in live.parents or live in self.root.parents:
            raise RuntimeError('Choose a separate prototype directory without symlinks')
        try:
            self.root.mkdir(mode=0o700, parents=True, exist_ok=True)
            self.directory = os.open(self.root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            self.secure(self.directory, directory=True)
            self.lock = os.open('session.lock', os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600, dir_fd=self.directory)
            self.secure(self.lock)
            try:
                fcntl.flock(self.lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise RuntimeError('This prototype session is already open') from None
            expected = {'version': 1, 'port': self.port, 'transport': 'mock', 'root': str(self.root)}
            try:
                descriptor = os.open('session.json', os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=self.directory)
            except FileNotFoundError:
                if set(os.listdir(self.directory)) != {'session.lock'}:
                    raise RuntimeError('Use an empty directory for a new prototype session') from None
                temporary = '.session-' + str(uuid.uuid4())
                descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=self.directory)
                with os.fdopen(descriptor, 'wb') as file:
                    file.write(json.dumps(expected, sort_keys=True).encode())
                    file.flush()
                    os.fsync(file.fileno())
                os.rename(temporary, 'session.json', src_dir_fd=self.directory, dst_dir_fd=self.directory)
                os.fsync(self.directory)
            else:
                with os.fdopen(descriptor, 'rb') as file:
                    self.secure(file.fileno())
                    data = file.read(4097)
                if len(data) > 4096 or json.loads(data) != expected:
                    raise RuntimeError('Session settings do not match; keep its original folder and port')
            for name in ('runtime', 'ui'):
                try:
                    os.mkdir(name, mode=0o700, dir_fd=self.directory)
                except FileExistsError:
                    pass
                descriptor = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=self.directory)
                try:
                    self.secure(descriptor, directory=True)
                finally:
                    os.close(descriptor)
            return self
        except BaseException:
            self.__exit__(None, None, None)
            raise

    def __exit__(self, kind: type[BaseException] | None, value: BaseException | None, traceback: TracebackType | None) -> None:
        if self.lock >= 0:
            os.close(self.lock)
            self.lock = -1
        if self.directory >= 0:
            os.close(self.directory)
            self.directory = -1


def main() -> int:
    parser = argparse.ArgumentParser(description='Start the separate Vera prototype with an explicit test runtime')
    parser.add_argument('--mock', action='store_true', required=True)
    parser.add_argument('--data-root', type=Path, required=True)
    parser.add_argument('--port', type=int, default=8769)
    parser.add_argument('--contract-test', action='store_true')
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[2]
    ui = repo / 'prototypes/assistant-ui/.build/debug/VeraPrototype'
    if not ui.is_file() or not os.access(ui, os.X_OK):
        print('Build the separate prototype first: mise run assistant-ui-test', file=sys.stderr)
        return 1
    os.umask(0o077)
    try:
        if not 1 <= args.port <= 65535:
            raise RuntimeError('Choose a port between 1 and 65535')
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
            listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            try:
                listener.bind(('127.0.0.1', args.port))
                listener.listen()
            except OSError:
                raise RuntimeError('That loopback port is busy; this session was not opened') from None
            with SessionState(args.data_root, args.port) as state:
                identity = str(uuid.uuid4())
                bridge = [sys.executable, str(repo / 'prototypes/pi_assistant/bridge.py'), '--data-root', str(state.root / 'runtime'), '--port', str(args.port), '--listen-fd', str(listener.fileno()), '--supervised', '--instance-id', identity]
                endpoint = 'http://127.0.0.1:' + str(args.port)
                workspace = state.root / 'runtime/workspaces'
                command = [str(ui), '--data-root', str(state.root / 'ui'), '--endpoint', endpoint, '--workspace-root', str(workspace)]
                if args.contract_test:
                    command.append('--contract-test')
                env = {'PATH': os.environ.get('PATH', '/usr/bin:/bin'), 'LANG': 'C.UTF-8', 'PYTHONDONTWRITEBYTECODE': '1'}
                print('Test runtime: the separate Vera prototype uses synthetic tasks.', flush=True)
                return run_session(bridge, command, listener, identity, workspace, env, lease_fd=state.lock)
    except RuntimeError as error:
        print(str(error), file=sys.stderr)
    except (OSError, ValueError, TypeError):
        print('The prototype session could not be opened safely. Its files were preserved.', file=sys.stderr)
    return 1


if __name__ == '__main__':
    raise SystemExit(main())
