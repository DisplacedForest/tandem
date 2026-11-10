#!/bin/sh
set -eu

PORT=8084
MODEL="mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit-dwq-v2"
PY="$HOME/venvs/vera/bin/python"
LOG=/tmp/vera-coder.log
PIDFILE=/tmp/vera-coder.pid

is_up() { curl -sf "http://127.0.0.1:$PORT/v1/models" >/dev/null 2>&1; }

case "${1:-ensure}" in
  start|ensure)
    if is_up; then echo "vera-coder: already up on :$PORT"; exit 0; fi
    echo "vera-coder: starting mlx_lm.server ($MODEL) on :$PORT ..."
    nohup "$PY" -m mlx_lm server \
      --model "$MODEL" --host 0.0.0.0 --port "$PORT" \
      > "$LOG" 2>&1 &
    echo $! > "$PIDFILE"
    i=0
    while [ "$i" -lt 120 ]; do
      if is_up; then echo "vera-coder: up on :$PORT"; exit 0; fi
      i=$((i + 1)); sleep 1
    done
    echo "vera-coder: failed to come up within 120s; see $LOG" >&2
    exit 1
    ;;
  stop)
    [ -f "$PIDFILE" ] && kill "$(cat "$PIDFILE")" 2>/dev/null || true
    rm -f "$PIDFILE"
    pkill -f "mlx_lm server --model $MODEL" 2>/dev/null || true
    echo "vera-coder: stopped (unified memory released)"
    ;;
  status)
    if is_up; then echo "vera-coder: UP on :$PORT"; else echo "vera-coder: down"; fi
    ;;
  *)
    echo "usage: $0 {ensure|start|stop|status}" >&2
    exit 2
    ;;
esac
