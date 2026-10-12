import json
import os
import signal
import socket
import subprocess
import threading
import time
from pathlib import Path
from types import FrameType


class _Interrupted(Exception):
    def __init__(self, signum: int) -> None:
        super().__init__("interrupted")
        self.signum = signum


def _ready(port: int, expected_instance: str, workspace_root: str) -> bool:
    deadline = time.monotonic() + .25
    data = bytearray()
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=.25) as connection:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return False
            connection.settimeout(remaining)
            connection.sendall(b"GET /assistant/capabilities HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\nAccept: application/json\r\n\r\n")
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0 or len(data) > 65536:
                    return False
                connection.settimeout(remaining)
                chunk = connection.recv(min(4096, 65537 - len(data)))
                if not chunk:
                    return False
                data.extend(chunk)
                if b"\r\n\r\n" not in data:
                    continue
                head, body = data.split(b"\r\n\r\n", 1)
                lines = head.split(b"\r\n")
                if not lines[0].startswith((b"HTTP/1.1 200 ", b"HTTP/1.0 200 ")):
                    return False
                headers = [line.partition(b":") for line in lines[1:]]
                lengths = [value.strip() for name, separator, value in headers if name.lower() == b"content-length" and separator]
                if len(lengths) != 1 or not lengths[0].isdigit() or len(lengths[0]) > 6 or any(name.lower() == b"transfer-encoding" for name, _, _ in headers):
                    return False
                length = int(lengths[0])
                if length > 65536 or len(data) > 65536:
                    return False
                if len(body) < length:
                    continue
                if len(body) != length:
                    return False
                value = json.loads(body)
                return isinstance(value, dict) and type(value.get("protocol_version")) is int and value["protocol_version"] == 1 and value.get("transport") == "mock" and value.get("instance_id") == expected_instance and value.get("workspace_root") == workspace_root
    except (OSError, ValueError, RecursionError):
        return False


def _stop(proc: subprocess.Popen[bytes] | None, graceful: bool) -> None:
    if proc is None:
        return
    if proc.stdin is not None:
        try:
            proc.stdin.close()
        except OSError:
            pass
    if graceful:
        try:
            proc.wait(2.0)
        except subprocess.TimeoutExpired:
            pass
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(proc.pid, sig)
        except ProcessLookupError:
            proc.wait(2.0)
            return
        deadline = time.monotonic() + 2.0
        while time.monotonic() < deadline:
            proc.poll()
            try:
                os.killpg(proc.pid, 0)
            except ProcessLookupError:
                proc.wait(2.0)
                return
            time.sleep(.02)
    raise RuntimeError("An owned prototype process did not stop; preserve this session")


def run_session(
    bridge_command: list[str],
    ui_command: list[str],
    listener: socket.socket,
    expected_instance: str,
    workspace: Path,
    env: dict[str, str],
    timeout: float = 10,
    lease_fd: int | None = None,
) -> int:
    if threading.current_thread() is not threading.main_thread():
        listener.close()
        raise RuntimeError("session must run in the main thread")
    bridge: subprocess.Popen[bytes] | None = None
    ui: subprocess.Popen[bytes] | None = None
    interrupted = 0
    def receive(signum: int, frame: FrameType | None) -> None:
        nonlocal interrupted
        if not interrupted:
            interrupted = signum
    previous = {sig: signal.getsignal(sig) for sig in (signal.SIGINT, signal.SIGTERM)}
    try:
        for sig in previous:
            signal.signal(sig, receive)
        try:
            host, port = listener.getsockname()[:2]
        except (OSError, ValueError):
            raise RuntimeError("invalid listener") from None
        if (
            listener.family != socket.AF_INET
            or listener.type != socket.SOCK_STREAM
            or host != "127.0.0.1"
            or not port
        ):
            raise RuntimeError("listener must be bound to 127.0.0.1")
        workspace_root = os.path.abspath(workspace)
        try:
            bridge = subprocess.Popen(
                bridge_command,
                stdin=subprocess.PIPE,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                pass_fds=(listener.fileno(),),
                env=env,
                start_new_session=True,
            )
        except (OSError, ValueError, subprocess.SubprocessError):
            raise RuntimeError("failed to start bridge") from None
        finally:
            listener.close()
        deadline = time.monotonic() + min(max(timeout, 0.0), 10.0)
        while True:
            if interrupted:
                raise _Interrupted(interrupted)
            if bridge.poll() is not None:
                raise RuntimeError("bridge exited during startup")
            if _ready(port, expected_instance, workspace_root):
                break
            if time.monotonic() >= deadline:
                raise RuntimeError("bridge readiness timed out")
            time.sleep(0.05)
        if interrupted:
            raise _Interrupted(interrupted)
        if bridge.poll() is not None:
            raise RuntimeError("bridge exited during startup")
        try:
            ui = subprocess.Popen(
                ui_command,
                pass_fds=(lease_fd,) if lease_fd is not None else (),
                stdin=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                env=env,
                start_new_session=True,
            )
        except (OSError, ValueError, subprocess.SubprocessError):
            raise RuntimeError("failed to start UI") from None
        while True:
            if interrupted:
                raise _Interrupted(interrupted)
            code = ui.poll()
            if code is not None:
                return code if code >= 0 else 128 - code
            if bridge.poll() is not None:
                return 1
            time.sleep(0.1)
    except _Interrupted as exc:
        return 130 if exc.signum == signal.SIGINT else 143
    finally:
        try:
            for sig in previous:
                signal.signal(sig, signal.SIG_IGN)
            try:
                _stop(ui, False)
            finally:
                _stop(bridge, True)
        finally:
            listener.close()
            for sig, handler in previous.items():
                signal.signal(sig, handler)