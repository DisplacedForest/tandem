import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import time


def run(binary):
    for mode, phase, count in [('metadata', 'metadataBegin', 0), ('credential', 'keychainBegin', 0), ('models', 'modelsBegin', 0), ('usage', 'usageBegin', 0), ('inference', 'inferenceBegin', 1), ('cancel', 'keychainBegin', 0), ('concurrent', 'inferenceBegin', 2), ('sqlite', None, 0)]:
        for blocked_stderr in [False, True] if mode == 'credential' else [False]:
            with tempfile.TemporaryDirectory(prefix='vera-watchdog-') as directory:
                root = Path(directory).resolve() / 'ledger'
                descriptors = None
                if blocked_stderr:
                    read_fd, write_fd = os.pipe()
                    os.set_blocking(write_fd, False)
                    while True:
                        try:
                            os.write(write_fd, b'x' * 4096)
                        except BlockingIOError:
                            break
                    descriptors = read_fd, write_fd
                started = time.monotonic()
                process = subprocess.Popen([str(binary), '--watchdog-test', mode, str(root)], stdout=subprocess.PIPE, stderr=descriptors[1] if descriptors else subprocess.PIPE)
                try:
                    out, err = process.communicate(timeout=5)
                finally:
                    if process.poll() is None:
                        process.kill()
                        process.communicate(timeout=2)
                    if descriptors:
                        for fd in descriptors:
                            os.close(fd)
                assert process.returncode == (125 if mode in {'cancel', 'concurrent'} else (126 if mode in {'metadata', 'credential'} else 124)), (mode, process.returncode, out, err)
                assert time.monotonic() - started < 3
                assert not out
                if not blocked_stderr:
                    assert err in (b'native_deadline_watchdog\n', b'native_cancel_watchdog\n', b'native_credential_watchdog\n')
                with sqlite3.connect(root / 'spend.sqlite') as db:
                    phases = [row[0] for row in db.execute('SELECT stage FROM phases ORDER BY sequence')]
                    assert (phase in phases if phase else phases == []) and 'settled' not in phases, phases
                    assert db.execute('SELECT credential_attempted FROM experiments').fetchone()[0] == (0 if mode == 'sqlite' else 1)
                    assert db.execute('SELECT COUNT(*) FROM requests').fetchone()[0] == count
                    assert db.execute("SELECT COUNT(*) FROM requests WHERE status='reserved'").fetchone()[0] == count
                reopened = subprocess.run([str(binary), '--lock-test', str(root)], capture_output=True, timeout=3)
                assert reopened.returncode == 0
                with sqlite3.connect(root / 'spend.sqlite') as db:
                    assert db.execute("SELECT COUNT(*) FROM requests WHERE status='uncertain'").fetchone()[0] == count
                    assert db.execute('SELECT credential_attempted FROM experiments').fetchone()[0] == (0 if mode == 'sqlite' else 1)
                for path in root.iterdir():
                    assert b'synthetic-stalled-key' not in path.read_bytes()
                print(f'PASS independent watchdog {mode} blocked_stderr={blocked_stderr}: bounded exit, stage retained, no refund or retry')


if __name__ == '__main__':
    run(Path(sys.argv[1]).resolve())
