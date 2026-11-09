#!/bin/sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/apps/vera-mac/Sources"

offenders=$(
    find "$SRC" -name '*.swift' -print0 | xargs -0 awk '
    {
        di = index($0, "\342\200\224")
        if (di == 0) next
        ci = index($0, "//")
        bi = index($0, "/*")
        cstart = 0
        if (ci > 0) cstart = ci
        if (bi > 0 && (cstart == 0 || bi < cstart)) cstart = bi
        if (cstart == 0 || di < cstart) printf "%s:%d: %s\n", FILENAME, FNR, $0
    }'
)

if [ -n "$offenders" ]; then
    echo "Em dash found in app copy (use periods, commas, or parentheses; comments are exempt):" >&2
    echo "$offenders" >&2
    exit 1
fi

echo "check-copy: OK (no em dashes in app copy outside comments)"
