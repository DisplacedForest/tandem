#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
fixture_home=$(mktemp -d "${TMPDIR:-/tmp}/vera-memory-check.XXXXXX")
trap 'rm -rf "$fixture_home"' EXIT
mkdir -p "$fixture_home/.vera" "$fixture_home/tmp"
CFFIXED_USER_HOME="$fixture_home" VERA_CONFIG_DIR="$fixture_home/.vera" TMPDIR="$fixture_home/tmp" "$root/.build/debug/Vera" --memory-gate-selftest
