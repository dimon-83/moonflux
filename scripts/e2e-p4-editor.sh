#!/bin/bash
# P4 gate (the milestone's own): drag a pipeline → run → consume data,
# through a real browser.
#
#   setup   build the editor kernel, stage the page, start the broker
#           (`serve --ws`) and a static server, print the editor URL
#   wait    block until the browser phase has produced data (the
#           assertions below are what makes this a gate rather than a
#           demo: they check the *data*, not the pixels)
#   verify  the deployed pipeline really ran: the topic holds the
#           records the editor produced, transformed by the editor's
#           chain, and the broker holds the editor's topology
#
# The browser phase is driven by whoever runs the gate (the agent in a
# session, or a human with the printed URL). Everything else — build,
# processes, assertions — is this script, so a failure is reproducible
# without a browser.
#
# Usage:
#   scripts/e2e-p4-editor.sh            # setup + wait + verify
#   scripts/e2e-p4-editor.sh setup      # leave the cluster running and print the URL
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXE="${MOONFLUX_EXE:-$ROOT/_build/native/release/build/apps/cli/cli.exe}"
[ -x "$EXE" ] || EXE="$ROOT/_build/native/debug/build/apps/cli/cli.exe"
[ -x "$EXE" ] || { echo "cli executable not found; run: moon build --target native" >&2; exit 1; }

WORK="${MOONFLUX_P4_WORK:-/tmp/moonflux-p4-editor}"
BROKER_PORT="${MOONFLUX_P4_BROKER_PORT:-19421}"
PAGE_PORT="${MOONFLUX_P4_PAGE_PORT:-19422}"
TOPIC="${MOONFLUX_P4_TOPIC:-editor-events}"
PAGE_DIR="$WORK/page"
STATE="$WORK/state.env"

fail() { echo "E2E-P4-EDITOR FAIL: $*" >&2; exit 1; }
pass() { echo "E2E-P4-EDITOR PASS: $*"; }

# Runs a consume with a hard deadline, writing to $WORK/consume.out.
# macOS has no `timeout(1)`, so the bound is a background kill.
timeout_consume() {
  local topic="$1"
  local out="$WORK/consume.out"
  rm -f "$out"
  ( "$EXE" consume --topic "$topic" --remote "127.0.0.1:$BROKER_PORT" > "$out" 2>/dev/null ) &
  local pid=$!
  local waited=0
  while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 25 ]; do
    sleep 0.2
    waited=$((waited + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null
    return 1
  fi
  wait "$pid" 2>/dev/null
  [ -s "$out" ]
}

setup() {
  rm -rf "$WORK"
  mkdir -p "$PAGE_DIR" "$WORK/broker" "$WORK/input"
  printf 'editor line one\neditor line two\n' > "$WORK/input/seed.txt"

  echo "[1/4] building the editor kernel (js target)"
  moon build --target js apps/editor-kernel > /dev/null 2>&1 \
    || fail "the editor kernel does not build for js"
  local kernel_js
  kernel_js="$(find "$ROOT/_build/js" -name editor-kernel.js | head -1)"
  [ -n "$kernel_js" ] || fail "no editor-kernel.js artifact"
  cp "$kernel_js" "$PAGE_DIR/editor-kernel.js"
  cp "$ROOT/web/editor/index.html" "$PAGE_DIR/index.html"

  echo "[2/4] starting the broker (serve --ws) on $BROKER_PORT"
  "$EXE" serve --data-dir "$WORK/broker" --listen "127.0.0.1:$BROKER_PORT" --ws \
    > "$WORK/broker.log" 2>&1 &
  echo "$!" > "$WORK/broker.pid"

  echo "[3/4] serving the editor page on $PAGE_PORT"
  ( cd "$PAGE_DIR" && python3 -m http.server "$PAGE_PORT" --bind 127.0.0.1 ) \
    > "$WORK/page.log" 2>&1 &
  echo "$!" > "$WORK/page.pid"

  for port in "$BROKER_PORT" "$PAGE_PORT"; do
    for _ in $(seq 1 60); do
      lsof -i ":$port" -sTCP:LISTEN > /dev/null 2>&1 && break
      sleep 0.1
    done
    lsof -i ":$port" -sTCP:LISTEN > /dev/null 2>&1 || fail "nothing listening on :$port"
  done

  echo "[4/4] ready"
  cat > "$STATE" <<EOF
WORK=$WORK
TOKEN=P4-EDITOR-OK
TOPIC=$TOPIC
EOF
  echo
  echo "  editor:  http://127.0.0.1:$PAGE_PORT/index.html?broker=$BROKER_PORT"
  echo "  broker:  ws://127.0.0.1:$BROKER_PORT  (serve --ws)"
  echo
  echo "  drive the editor: add a source (file: $WORK/input/seed.txt), a"
  echo "  transform (expr: upper(value)), a sink; deploy; run; consume."
}

cleanup() {
  [ -f "$WORK/broker.pid" ] && kill "$(cat "$WORK/broker.pid")" 2>/dev/null || true
  [ -f "$WORK/page.pid" ] && kill "$(cat "$WORK/page.pid")" 2>/dev/null || true
}

verify() {
  local topic="$TOPIC"

  # 1. the editor's pipeline is what the broker holds
  [ -f "$WORK/broker/topology.json" ] \
    || fail "the broker has no applied pipeline: deploy never reached it"
  grep -q '"pipeline"' "$WORK/broker/topology.json" \
    || fail "topology.json does not name a pipeline"
  local staged
  staged="$(grep -o '"editor-demo"\|"editor-events"' "$WORK/broker/topology.json" | sort -u | tr '\n' ' ')"
  pass "the broker holds the editor's topology ($staged)"

  # 2. records reached the log (read from disk: the log file IS the
  #    protocol stream, so this needs no connection at all)
  # P8: a partition is a directory of segments; the frames are their
  # concatenation in base order (the names sort as offsets)
  local log_dir="$WORK/broker/topics/$topic/partition-0"
  local log_file="$WORK/editor-log.bin"
  : > "$log_file"
  for f in $(ls "$log_dir"/*.log 2>/dev/null | sort); do
    cat "$f" >> "$log_file"
  done
  [ -s "$log_file" ] || fail "the editor never produced anything (no segments under $log_dir)"
  local on_disk
  on_disk="$(python3 "$ROOT/tools/decode_log_frames.py" "$log_file")" \
    || fail "the on-disk frames do not decode"
  [ -n "$on_disk" ] || fail "the log is empty"
  pass "the topic log holds $(printf '%s\n' "$on_disk" | wc -l | tr -d ' ') record(s), written by the browser"

  # 3. the deployed chain runs on the consumption path. The broker
  #    serves connections concurrently (P5), so this read happens while
  #    the editor still holds its WebSocket open — the case that used to
  #    be impossible.
  timeout_consume "$topic" || fail "the broker did not answer a read while the editor is connected"
  local out
  out="$(cat "$WORK/consume.out")"
  [ -n "$out" ] || fail "the broker returned no records"
  printf '%s\n' "$out" | cut -f4- | grep -q "^[A-Z0-9 ,.-]*$" \
    || { printf '%s\n' "$out"; fail "the deployed transform did not run (records are not upper-cased)"; }
  printf '%s\n' "$out" | cut -f4- | grep -qi "hello world" \
    || { printf '%s\n' "$out"; fail "the editor's sample records are not what came back"; }
  pass "the deployed expr chain ran: the records came back upper-cased (read while the browser stayed connected)"

  local first
  first="$(printf '%s\n' "$out" | head -1 | cut -f4-)"
  [ "$first" = "HELLO WORLD" ] || fail "expected HELLO WORLD first, got '$first'"
  pass "compose → deploy → run → consume works end to end through a browser"
}

case "${1:-all}" in
  setup) setup ;;
  verify) verify ;;
  all)
    setup
    echo "waiting for the browser phase (up to 10 minutes)…"
    deadline=$((SECONDS + 600))
    while [ "$SECONDS" -lt "$deadline" ]; do
      if [ -f "$WORK/broker/topology.json" ] && \
         "$EXE" consume --topic "$TOPIC" --remote "127.0.0.1:$BROKER_PORT" 2>/dev/null | grep -q .; then
        break
      fi
      sleep 2
    done
    verify
    cleanup
    ;;
  *) fail "unknown mode '$1' (setup|verify|all)" ;;
esac
