#!/bin/bash
set -uo pipefail

[ -f "$HOME/.vera/offsite.env" ] && . "$HOME/.vera/offsite.env"

SSH_HOST="${VERA_BACKUP_SSH_HOST:-}"
REMOTE_ROOT="${VERA_BACKUP_REMOTE_ROOT:-}"
LOCAL_ROOT="${VERA_BACKUP_LOCAL_ROOT:-$HOME/VeraBackups}"
ICLOUD_DIR="${VERA_BACKUP_ICLOUD_DIR:-$HOME/Library/Mobile Documents/com~apple~CloudDocs/VeraBackups}"
RECIPIENT="${VERA_OFFSITE_AGE_RECIPIENT:-}"
AGE="${VERA_AGE_BIN:-/opt/homebrew/bin/age}"
KEEP_LOCAL="${VERA_BACKUP_KEEP_LOCAL:-14}"
KEEP_ICLOUD="${VERA_BACKUP_KEEP_ICLOUD:-14}"
LOG="$HOME/Library/Logs/vera-offsite.log"

exec >>"$LOG" 2>&1
log() { echo "[$(date +%FT%T)] $*"; }
[ -n "$SSH_HOST" ] && [ -n "$REMOTE_ROOT" ] && [ -n "$RECIPIENT" ] || {
  log "FAIL unconfigured: set VERA_BACKUP_SSH_HOST, VERA_BACKUP_REMOTE_ROOT, VERA_OFFSITE_AGE_RECIPIENT (env or ~/.vera/offsite.env)"
  exit 1
}
mkdir -p "$LOCAL_ROOT" "$ICLOUD_DIR"

STAMP="$(ssh "$SSH_HOST" "ls -1 '$REMOTE_ROOT' | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}_' | sort | tail -1")"
[ -n "$STAMP" ] || { log "FAIL no remote snapshot found"; exit 1; }
log "newest remote snapshot: $STAMP"

if rsync -a --delete "$SSH_HOST:$REMOTE_ROOT/$STAMP/" "$LOCAL_ROOT/$STAMP/"; then
  log "OK   pulled -> $LOCAL_ROOT/$STAMP ($(du -sh "$LOCAL_ROOT/$STAMP" | cut -f1))"
else
  log "FAIL rsync pull"; exit 1
fi

if grep -v ' SHA256SUMS$' "$LOCAL_ROOT/$STAMP/SHA256SUMS" \
     | ( cd "$LOCAL_ROOT/$STAMP" && shasum -a 256 -c --status - ); then
  log "OK   checksums verified"
else
  log "FAIL checksum mismatch: not promoting to iCloud"; exit 1
fi

BLOB="$ICLOUD_DIR/vera-$STAMP.tar.age"
if tar c -C "$LOCAL_ROOT" "$STAMP" | "$AGE" -r "$RECIPIENT" -o "$BLOB"; then
  log "OK   encrypted -> $BLOB ($(du -h "$BLOB" | cut -f1))"
else
  log "FAIL encrypt"; rm -f "$BLOB"; exit 1
fi

ls -1dt "$LOCAL_ROOT"/*/ 2>/dev/null | tail -n +$((KEEP_LOCAL+1)) | while read -r d; do rm -rf "$d"; done
ls -1t  "$ICLOUD_DIR"/vera-*.tar.age 2>/dev/null | tail -n +$((KEEP_ICLOUD+1)) | while read -r f; do rm -f "$f"; done
log "OK   retention applied (local<=$KEEP_LOCAL iCloud<=$KEEP_ICLOUD)"
log "done -> $STAMP"
