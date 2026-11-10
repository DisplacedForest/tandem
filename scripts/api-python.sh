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
lock_dir="$env_dir.lock"

if [ -f "$marker" ]; then
  exec "$env_dir/bin/python" "$@"
fi

mkdir -p "$venv_root"

waited=0
ownerless=0
timeout=600
while ! mkdir "$lock_dir" 2>/dev/null; do
  if [ -f "$marker" ]; then
    exec "$env_dir/bin/python" "$@"
  fi
  holder=$(cat "$lock_dir/pid" 2>/dev/null || true)
  if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then
    echo "api-python: removing stale lock left by process $holder" >&2
    rm -rf "$lock_dir"
    continue
  fi
  if [ -z "$holder" ]; then
    ownerless=$((ownerless + 1))
  else
    ownerless=0
  fi
  if [ "$ownerless" -ge 5 ]; then
    echo "api-python: removing lock with no owner" >&2
    rm -rf "$lock_dir"
    ownerless=0
    continue
  fi
  if [ "$waited" -ge "$timeout" ]; then
    echo "api-python: gave up after ${timeout}s waiting for another process to build $env_dir" >&2
    exit 1
  fi
  if [ "$waited" -eq 0 ]; then
    echo "api-python: waiting for another process to build $env_dir" >&2
  fi
  sleep 1
  waited=$((waited + 1))
done

echo "$$" > "$lock_dir/pid"
trap 'rm -rf "$lock_dir"' EXIT
trap 'rm -rf "$lock_dir"; exit 130' INT
trap 'rm -rf "$lock_dir"; exit 143' TERM

if [ ! -f "$marker" ]; then
  if [ -d "$env_dir" ]; then
    rm -rf "$env_dir"
  fi
  echo "api-python: building $env_dir with $base ($base_version)" >&2
  "$base" -m venv --copies "$env_dir" >&2
  "$env_dir/bin/python" -m pip install --quiet --disable-pip-version-check \
    -r "$runtime_lock" -r "$dev_lock" >&2
  : > "$marker"
fi

rm -rf "$lock_dir"
trap - EXIT INT TERM

exec "$env_dir/bin/python" "$@"
