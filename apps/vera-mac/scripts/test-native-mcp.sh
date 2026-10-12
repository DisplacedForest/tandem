#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
fixture_home=$(mktemp -d "${TMPDIR:-/tmp}/vera-mcp-check.XXXXXX")
trap 'rm -rf "$fixture_home"' EXIT
mkdir -p "$fixture_home/.vera" "$fixture_home/tmp"
CFFIXED_USER_HOME="$fixture_home" VERA_CONFIG_DIR="$fixture_home/.vera" TMPDIR="$fixture_home/tmp" "$root/.build/debug/Vera" --mcp-selftest --repo "$(CDPATH= cd -- "$root/../.." && pwd)" --python "$(command -v python)" --node "$(command -v node)" --root "$fixture_home/runtime" --port 0
