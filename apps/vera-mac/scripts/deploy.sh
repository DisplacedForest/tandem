#!/usr/bin/env bash
set -euo pipefail

APP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$APP_ROOT"

"$APP_ROOT/../../scripts/check-copy.sh"
"$APP_ROOT/scripts/package.sh"

APP="$APP_ROOT/build/Tandem.app"
VERSION="$(cat "$APP_ROOT/../../VERSION" | tr -d '[:space:]')"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/vera-deploy.XXXXXXXX")"
trap 'rm -rf "$WORK"' EXIT
xcrun swiftc -swift-version 6 -target "$(uname -m)-apple-macosx26.0" "$APP_ROOT/Sources/Vera/SafeAppReplacement.swift" \
  "$APP_ROOT/scripts/app-replacement/main.swift" -o "$WORK/app-replacement"

if [ -d /Applications/Vera.app ] && [ ! -d /Applications/Tandem.app ]; then
  mv /Applications/Vera.app /Applications/Tandem.app
fi
printf '%s\n' '==> Install to /Applications; retaining rollback bundle'
"$WORK/app-replacement" "$APP" /Applications/Tandem.app "$VERSION" --first-install

HOST="${VERA_STUDIO_HOST:-}"
if [ -z "$HOST" ]; then
  printf '%s\n' '==> Remote: VERA_STUDIO_HOST not set. Skipping remote deploy.'
  exit 0
fi
if ! ssh -o ConnectTimeout=5 -o BatchMode=yes -- "$HOST" true 2>/dev/null; then
  printf '==> Remote (%s) unreachable. Skipping remote deploy.\n' "$HOST"
  exit 0
fi

/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$WORK/Tandem.app.zip"
REMOTE="$(ssh -- "$HOST" '/usr/bin/mktemp -d /tmp/vera-deploy.XXXXXXXX')"
if [[ ! "$REMOTE" =~ ^/tmp/vera-deploy\.[a-zA-Z0-9]+$ ]]; then
  printf '%s\n' 'Remote staging directory is invalid' >&2
  exit 1
fi
scp -q -- "$WORK/Tandem.app.zip" "$WORK/app-replacement" "$HOST:$REMOTE/"
ssh -- "$HOST" /bin/sh -s -- "$REMOTE" "$VERSION" <<'REMOTE_SCRIPT'
set -eu
work="$1"
version="$2"
trap 'rm -rf "$work"' EXIT
/usr/bin/ditto -x -k "$work/Tandem.app.zip" "$work"
/bin/chmod 700 "$work/app-replacement"
if [ -d /Applications/Vera.app ] && [ ! -d /Applications/Tandem.app ]; then
  /bin/mv /Applications/Vera.app /Applications/Tandem.app
fi
"$work/app-replacement" "$work/Tandem.app" /Applications/Tandem.app "$version" --first-install
REMOTE_SCRIPT
printf '    deployed to %s:/Applications/Tandem.app\n' "$HOST"
