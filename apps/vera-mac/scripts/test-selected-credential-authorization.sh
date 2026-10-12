#!/usr/bin/env bash
set -euo pipefail
APP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/vera-credential-fixture.XXXXXXXX")"
trap 'rm -rf "$WORK"' EXIT
xcrun swiftc -swift-version 6 -module-cache-path "$WORK/module-cache" "$APP_ROOT/Sources/Vera/SelectedCredentialAuthorization.swift" \
  "$APP_ROOT/Tests/SelectedCredentialAuthorizationTests.swift" -o "$WORK/fixture"
"$WORK/fixture"
