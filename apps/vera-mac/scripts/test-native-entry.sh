#!/bin/sh
set -eu
root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/vera-entry.XXXXXXXX")"
trap 'rm -rf "$work"' EXIT
xcrun swiftc -module-cache-path "$work/module-cache" -swift-version 6 "$root/Sources/Vera/NativeApplicationEntry.swift" "$root/Tests/native-entry/main.swift" -o "$work/entry"
"$work/entry" progress
"$work/entry" deadline
"$work/entry" async
"$work/entry" forced-cleanup
