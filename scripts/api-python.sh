#!/usr/bin/env bash
set -eu

script_dir=$(cd "$(dirname "$0")" && pwd -P)
worktree_root=$(cd "$script_dir/.." && pwd -P)
api_dir="$worktree_root/services/vera-api"
runtime_lock="$api_dir/requirements.txt"
dev_lock="$api_dir/requirements-dev.txt"

common_dir=$(
  cd "$worktree_root" &&
    env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_OBJECT_DIRECTORY \
      -u GIT_ALTERNATE_OBJECT_DIRECTORIES -u GIT_COMMON_DIR -u GIT_PREFIX \
      -u GIT_NAMESPACE -u GIT_CEILING_DIRECTORIES \
      git rev-parse --path-format=absolute --git-common-dir 2>/dev/null
) || common_dir=""

if [ -n "$common_dir" ] && [ -d "$common_dir" ]; then
  primary_root=$(cd "$common_dir/.." && pwd -P)
else
  primary_root="$worktree_root"
fi

if [ -n "${TANDEM_API_PYTHON:-}" ]; then
  base="$TANDEM_API_PYTHON"
  if ! command -v "$base" >/dev/null 2>&1; then
    echo "api-python: TANDEM_API_PYTHON is set to $base, which was not found" >&2
    exit 1
  fi
elif command -v python3.12 >/dev/null 2>&1; then
  base=python3.12
else
  echo "api-python: Python 3.12 is needed (install python3.12 on PATH or set TANDEM_API_PYTHON)" >&2
  exit 1
fi

base_version=$("$base" -c 'import sys; print("%d.%d" % sys.version_info[:2])')

if command -v shasum >/dev/null 2>&1; then
  hash_cmd="shasum -a 256"
else
  hash_cmd="sha256sum"
fi

key=$({ cat "$runtime_lock" "$dev_lock"; printf '%s\n' "$base_version" copies; } | $hash_cmd | cut -c1-16)

venv_root="${TANDEM_API_VENV_ROOT:-$primary_root/.venv}"
env_dir="$venv_root/api-$key"
marker="$env_dir/.ready"

if [ -f "$marker" ]; then
  exec "$env_dir/bin/python" "$@"
fi

mkdir -p "$venv_root"

"$base" - "$env_dir" "$runtime_lock" "$dev_lock" >&2 <<'PY'
import fcntl
import shutil
import subprocess
import sys
import time
from pathlib import Path

env_dir = Path(sys.argv[1])
locks = sys.argv[2:]
marker = env_dir / ".ready"
deadline = time.monotonic() + 600
announced = False

with open(f"{env_dir}.lock", "w") as handle:
    while True:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            break
        except BlockingIOError:
            if time.monotonic() > deadline:
                sys.exit(f"api-python: gave up waiting for another process to build {env_dir}")
            if not announced:
                print(f"api-python: waiting for another process to build {env_dir}", flush=True)
                announced = True
            time.sleep(1)
    if not marker.exists():
        if env_dir.exists():
            shutil.rmtree(env_dir)
        print(f"api-python: building {env_dir}", flush=True)
        subprocess.run([sys.executable, "-m", "venv", "--copies", str(env_dir)], check=True, pass_fds=[handle.fileno()])
        install = [str(env_dir / "bin" / "python"), "-m", "pip", "install", "--quiet", "--disable-pip-version-check"]
        for lock in locks:
            install += ["-r", lock]
        subprocess.run(install, check=True, pass_fds=[handle.fileno()])
        marker.touch()
PY

exec "$env_dir/bin/python" "$@"
