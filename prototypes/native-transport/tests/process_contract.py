import hashlib
import json
import os
from pathlib import Path
import signal
import select
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
import uuid


def identifier() -> str:
    return str(uuid.uuid4())


def encode(value: object) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()


def private_json(path: Path, value: object) -> None:
    path.write_bytes(encode(value))
    path.chmod(0o600)


def snapshot(root: Path) -> list[tuple[str, str, int]]:
    try:
        with sqlite3.connect(f"file:{root / 'ledger/spend.sqlite'}?mode=ro", uri=True) as db:
            return db.execute("SELECT id,status,reserved FROM requests").fetchall()
    except sqlite3.OperationalError:
        return []


def wait_reserved(root: Path, process: subprocess.Popen[bytes]) -> None:
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        rows = snapshot(root)
        if rows and rows[0][1] == "reserved":
            return
        if process.poll() is not None:
            raise AssertionError("mock helper exited before reservation")
        time.sleep(0.01)
    raise AssertionError("mock helper did not reserve")


def run(binary: Path) -> None:
    digest = hashlib.sha256(binary.read_bytes()).hexdigest()
    for mode in ("eof", "cancel", "sigkill", "backpressure"):
        with tempfile.TemporaryDirectory(prefix="vera-native-pipe-") as directory:
            root = Path(directory).resolve()
            permits = root / "requests"
            permits.mkdir(mode=0o700)
            now = time.time()
            experiment, session, task = identifier(), identifier(), identifier()
            permit = {
                "experiment_id": experiment, "reconciliation_id": identifier(),
                "profile_id": identifier(), "issued_at": now - 1, "expires_at": now + 600,
                "prior_test_spend_usd": "0", "budget_usd": "1", "max_requests": 12,
                "exclusive_test_owner": True, "budget_scope": "vera-tests",
                "credential_access": "noninteractive-once", "transport": "mock",
                "sessions": [{"id": session, "task_id": task, "role": "foreground"}],
            }
            private_json(root / "permit.json", permit)
            request = {"op": "complete", "mode": "assistant", "request_id": identifier(), "session_id": session,
                       "task_id": task, "role": "foreground",
                       "messages": [{"role": "user", "content": "Disposable pipe test"}]}

            def authorize(value: dict[str, object]) -> None:
                private_json(permits / f"{value['request_id']}.json", {
                    "request_id": value["request_id"], "experiment_id": experiment,
                    "input_sha256": hashlib.sha256(encode(value)).hexdigest(),
                })

            authorize(request)
            args = [str(binary), "--mock-stdio", "--permit", str(root / "permit.json"),
                    "--request-permits", str(permits), "--ledger-root", str(root / "ledger"),
                    "--approved-sha256", digest]
            process = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                       stderr=subprocess.PIPE, start_new_session=True, bufsize=0)
            try:
                assert process.stdin is not None
                process.stdin.write(encode(request) + b"\n")
                process.stdin.flush()
                wait_reserved(root, process)
                started = time.monotonic()
                if mode == "sigkill":
                    os.killpg(process.pid, signal.SIGKILL)
                    out, err = process.communicate(timeout=3)
                    assert snapshot(root)[0][1] == "reserved"
                    fresh = dict(request, request_id=identifier())
                    authorize(fresh)
                    process = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                               stderr=subprocess.PIPE, start_new_session=True, bufsize=0)
                    assert process.stdin is not None and process.stdout is not None
                    process.stdin.write(encode(request) + b"\n" + encode(fresh) + b"\n")
                    process.stdin.flush()
                    lines = []
                    for _ in range(2):
                        ready, _, _ = select.select([process.stdout], [], [], 3)
                        assert ready
                        lines.append(process.stdout.readline())
                    process.stdin.close()
                    process.stdin = None
                    tail, err = process.communicate(timeout=3)
                    out = b"".join(lines) + tail
                    replies = [json.loads(line) for line in out.splitlines()]
                    assert {reply["error"] for reply in replies} == {"duplicate", "uncertain"}, replies
                    assert len(snapshot(root)) == 1
                elif mode == "backpressure":
                    def flood() -> None:
                        try:
                            assert process.stdin is not None
                            process.stdin.write(b'{"request_id":"invalid"}\n' * 20000)
                            process.stdin.flush()
                        except (BrokenPipeError, ValueError):
                            pass
                        finally:
                            try:
                                process.stdin.close()
                            except (BrokenPipeError, ValueError):
                                pass
                    writer = threading.Thread(target=flood, daemon=True)
                    writer.start()
                    process.wait(timeout=4)
                    writer.join(timeout=1)
                    assert not writer.is_alive()
                    assert process.stdout is not None and process.stderr is not None
                    out, err = process.stdout.read(), process.stderr.read()
                    assert process.returncode != 0
                    verify = subprocess.run([str(binary), "--lock-test", str(root / "ledger")], capture_output=True, timeout=3)
                    assert verify.returncode == 0, verify.stdout
                else:
                    if mode == "cancel":
                        process.stdin.write(encode({"op": "cancel", "request_id": request["request_id"]}) + b"\n")
                        process.stdin.flush()
                    process.stdin.close()
                    process.stdin = None
                    out, err = process.communicate(timeout=3)
                    assert json.loads(out)["error"] == "canceled", out
                assert time.monotonic() - started < 4
                assert snapshot(root)[0][1] == "uncertain"
                assert b"synthetic-broker-key" not in out + err
                for file in (root / "ledger").iterdir():
                    assert b"synthetic-broker-key" not in file.read_bytes()
                print(f"PASS native private-pipe {mode}: no duplicate inference, uncertain reservation retained")
            finally:
                if process.poll() is None:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.communicate(timeout=3)
    refused = subprocess.run([str(binary)], capture_output=True, timeout=3)
    assert refused.returncode == 1 and json.loads(refused.stdout)["error"] == "unauthorized"
    print("PASS default launch refuses live access")


if __name__ == "__main__":
    run(Path(sys.argv[1]).resolve())
