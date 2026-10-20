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

MIGRATED=0
if [ -d /Applications/Vera.app ] && [ ! -d /Applications/Tandem.app ]; then
  mv /Applications/Vera.app /Applications/Tandem.app
  MIGRATED=1
fi
printf '%s\n' '==> Install to /Applications; retaining rollback bundle'
if ! RECEIPT="$("$WORK/app-replacement" "$APP" /Applications/Tandem.app "$VERSION" --first-install)"; then
  if [ "$MIGRATED" = 1 ] && [ ! -d /Applications/Vera.app ]; then
    mv /Applications/Tandem.app /Applications/Vera.app
    printf '%s\n' '    install failed; restored /Applications/Vera.app' >&2
  fi
  exit 1
fi
printf '%s\n' "$RECEIPT"
if [ -d /Applications/Vera.app ]; then
  mv /Applications/Vera.app "$(dirname "$RECEIPT")/Vera.app"
  printf '%s\n' '    moved the previous Vera.app beside the rollback receipt'
fi
if [ "$(osascript -e 'application id "app.vera.mac" is running' 2>/dev/null)" = true ]; then
  osascript -e 'tell application id "app.vera.mac" to quit' >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ "$(osascript -e 'application id "app.vera.mac" is running' 2>/dev/null)" = true ] || break
    sleep 1
  done
  open /Applications/Tandem.app
  printf '%s\n' '    relaunched Tandem from /Applications/Tandem.app'
fi

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
migrated=0
if [ -d /Applications/Vera.app ] && [ ! -d /Applications/Tandem.app ]; then
  /bin/mv /Applications/Vera.app /Applications/Tandem.app
  migrated=1
fi
if ! receipt="$("$work/app-replacement" "$work/Tandem.app" /Applications/Tandem.app "$version" --first-install)"; then
  if [ "$migrated" = 1 ] && [ ! -d /Applications/Vera.app ]; then
    /bin/mv /Applications/Tandem.app /Applications/Vera.app
  fi
  exit 1
fi
printf '%s\n' "$receipt"
if [ -d /Applications/Vera.app ]; then
  /bin/mv /Applications/Vera.app "$(dirname "$receipt")/Vera.app"
fi
REMOTE_SCRIPT
printf '    deployed to %s:/Applications/Tandem.app\n' "$HOST"
