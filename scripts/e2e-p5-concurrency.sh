#!/bin/bash
# P5 gate: concurrency — one thread serves many connections, and nothing
# starves anyone.
#
# The defect this exists for: `serve` used to handle one connection at a
# time, so a browser's persistent WebSocket held the only slot and every
# other client looked like a hung cluster (P4's gate hit it).
#
#   1. a browser-shaped WebSocket connection stays open and idle, and
#      the CLI still produces and consumes — promptly
#   2. a connection that connects and says nothing at all does not delay
#      anyone either
#   3. two CLI clients run concurrently: both succeed
#   4. a client that sends half a frame and stalls does not block others
#   5. both transports at once: a WebSocket session and a CLI session
#      interleave, each getting correct answers
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# The debug build is what `moon build --target native` (and `moon test`)
# produce, so it is the artifact every gate here means to test. A release
# binary is only a fallback: preferring it once meant a gate silently
# tested a build from an earlier session.
EXE="${MOONFLUX_EXE:-$ROOT/_build/native/debug/build/apps/cli/cli.exe}"
[ -x "$EXE" ] || EXE="$ROOT/_build/native/release/build/apps/cli/cli.exe"
[ -x "$EXE" ] || { echo "cli executable not found; run: moon build --target native" >&2; exit 1; }

WORK="$(mktemp -d /tmp/moonflux-p5-concurrency.XXXXXX)"
PORT="${MOONFLUX_P5_PORT:-19461}"
SERVER_PID=""
PY_PIDS=()
cleanup() {
  for pid in "${PY_PIDS[@]:-}"; do kill "$pid" 2>/dev/null || true; done
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

fail() { echo "E2E-P5-CONCURRENCY FAIL: $*" >&2; exit 1; }
pass() { echo "E2E-P5-CONCURRENCY PASS: $*"; }

# bounded command: the point of this gate is that nothing hangs, so every
# client call gets a deadline (macOS has no timeout(1))
bounded() { # $1 = seconds, rest = command
  local deadline="$1"
  shift
  # a per-call file: concurrent callers must not clobber each other's
  # output (the first cut shared one path and the second caller's run
  # looked empty)
  local out
  out="$(mktemp "$WORK/bounded.XXXXXX")"
  ( "$@" > "$out" 2>&1 ) &
  local pid=$!
  local waited=0
  local ticks=$((deadline * 5))
  while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt "$ticks" ]; do
    sleep 0.2
    waited=$((waited + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null
    return 1
  fi
  wait "$pid" 2>/dev/null
  cat "$out"
  rm -f "$out"
}

wait_listen() {
  for _ in $(seq 1 60); do
    lsof -i ":$1" -sTCP:LISTEN > /dev/null 2>&1 && return 0
    sleep 0.1
  done
  return 1
}

printf 'p5-a\np5-b\n' > "$WORK/in.txt"
"$EXE" serve --data-dir "$WORK/data" --listen "127.0.0.1:$PORT" --ws > "$WORK/serve.log" 2>&1 &
SERVER_PID=$!
wait_listen "$PORT" || { cat "$WORK/serve.log"; fail "serve did not start"; }

# ---- 1. an idle browser connection must not starve the CLI ------------
python3 "$ROOT/scripts/testdata/p5_hold_ws.py" "$PORT" open > "$WORK/hold.log" 2>&1 &
HOLD_PID=$!
PY_PIDS+=("$HOLD_PID")
for _ in $(seq 1 40); do
  grep -q "holding" "$WORK/hold.log" 2>/dev/null && break
  sleep 0.25
done
grep -q "holding" "$WORK/hold.log" || { cat "$WORK/hold.log"; fail "the websocket holder did not start"; }

bounded 8 "$EXE" produce --topic p5 --file "$WORK/in.txt" --remote "127.0.0.1:$PORT" > /dev/null \
  || fail "produce was starved by an idle websocket connection"
OUT="$(bounded 8 "$EXE" consume --topic p5 --remote "127.0.0.1:$PORT")" \
  || fail "consume was starved by an idle websocket connection"
printf '%s\n' "$OUT" | cut -f4- | grep -q "p5-a" || fail "consume returned the wrong records"
pass "an idle websocket connection does not starve the CLI"

# ---- 2. a connection that says nothing at all -------------------------
python3 "$ROOT/scripts/testdata/p5_hold_ws.py" "$PORT" silent > "$WORK/silent.log" 2>&1 &
SILENT_PID=$!
PY_PIDS+=("$SILENT_PID")
sleep 0.5
OUT="$(bounded 8 "$EXE" consume --topic p5 --remote "127.0.0.1:$PORT")" \
  || fail "a silent connection starved the CLI"
printf '%s\n' "$OUT" | grep -q "p5-a" || fail "consume returned nothing with a silent peer present"
pass "a connection that sends nothing does not delay anyone"

# ---- 3. two CLI clients at once ---------------------------------------
( bounded 10 "$EXE" produce --topic p5 --file "$WORK/in.txt" --remote "127.0.0.1:$PORT" > "$WORK/c1.out" 2>&1 ) &
C1=$!
( bounded 10 "$EXE" consume --topic p5 --remote "127.0.0.1:$PORT" > "$WORK/c2.out" 2>&1 ) &
C2=$!
wait "$C1" || fail "concurrent produce failed"
wait "$C2" || fail "concurrent consume failed"
grep -q "produced" "$WORK/c1.out" || { cat "$WORK/c1.out"; fail "concurrent produce produced nothing"; }
grep -q "p5-a" "$WORK/c2.out" || { cat "$WORK/c2.out"; fail "concurrent consume returned nothing"; }
pass "two CLI clients ran concurrently and both succeeded"

# ---- 4. half a frame, then silence ------------------------------------
python3 "$ROOT/scripts/testdata/p5_hold_ws.py" "$PORT" partial > "$WORK/partial.log" 2>&1 &
PARTIAL_PID=$!
PY_PIDS+=("$PARTIAL_PID")
sleep 0.5
OUT="$(bounded 8 "$EXE" consume --topic p5 --remote "127.0.0.1:$PORT")" \
  || fail "a stalled partial frame blocked the server"
printf '%s\n' "$OUT" | grep -q "p5-a" || fail "consume returned nothing with a stalled peer"
pass "a half-sent frame does not block the loop"

# ---- 5. both transports at once ---------------------------------------
# the WebSocket client runs a real HELLO/PRODUCE/FETCH while the CLI
# does the same thing over TCP
python3 "$ROOT/scripts/testdata/p5_hold_ws.py" "$PORT" session > "$WORK/ws-session.log" 2>&1 &
WS_PID=$!
PY_PIDS+=("$WS_PID")
OUT="$(bounded 8 "$EXE" consume --topic p5 --remote "127.0.0.1:$PORT")" \
  || fail "the CLI stalled while a websocket session ran"
wait "$WS_PID" || { cat "$WORK/ws-session.log"; fail "the websocket session failed"; }
grep -q "websocket session ok" "$WORK/ws-session.log" \
  || { cat "$WORK/ws-session.log"; fail "the websocket session did not complete"; }
printf '%s\n' "$OUT" | grep -q "p5-a" || fail "the CLI got nothing during the websocket session"
pass "a websocket session and CLI clients interleave correctly"

# ---- and the log says what happened -----------------------------------
grep -q "serving connections concurrently" "$WORK/serve.log" \
  || { cat "$WORK/serve.log"; fail "the server did not report the multiplexed loop"; }
pass "the server ran the poll-driven loop (see: serve.log)"

echo "E2E-P5-CONCURRENCY: all green"
