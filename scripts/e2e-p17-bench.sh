#!/usr/bin/env bash
# E2E-P17: the benchmark reports, the gate checks structure.
#
# The reference system's benchmark is a producer throughput run plus a
# latency histogram; its consumer benchmark is hidden and unpublished
# (evaluation report §2.12). moonflux's adds the consume and the
# produce→consume visibility modes, because the P16 regression guard
# needs both directions of the path.
#
# Numbers are reports, never gates (decision 33 — the wall clock only
# reports; a gate that fails by machine load is a gate nobody trusts).
# What this gate falsifies is structure:
#
#   1. a produce run reports exact counts and a contiguous offset range,
#      with a monotone latency histogram and one batch per timing sample
#   2. a verified consume reads back exactly what was produced — every
#      value's offset header names its own offset — and the drain ends
#      at the server's scan_end, not at a guess
#   3. the same round trip works on the local path (the storage
#      baseline: no server, no transport)
#   4. a latency run produces and consumes every sample, and both
#      histograms are monotone (and e2e never claims to be faster than
#      the produce ack it contains)
#   5. the P16 regression guard: through the whole run the server
#      opened each topic's log exactly once — a regression to
#      per-request opens shows up here as a counter, not as a slowdown
#   6. a record over the per-field limit is refused by name in the
#      producer's own process, and the broker keeps serving
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXE="${MOONFLUX_EXE:-$ROOT/_build/native/debug/build/apps/cli/cli.exe}"
[ -x "$EXE" ] || EXE="$ROOT/_build/native/release/build/apps/cli/cli.exe"
[ -x "$EXE" ] || {
  echo "cli executable not found; run: moon build --target native" >&2
  exit 1
}

WORK="$(mktemp -d /tmp/moonflux-p17-bench.XXXXXX)"
BROKER_PORT="${MOONFLUX_P17_BROKER_PORT:-19701}"
BROKER_PID=""
TOPIC="${MOONFLUX_P17_TOPIC:-bench}"
LAT_TOPIC="${MOONFLUX_P17_LATENCY_TOPIC:-bench2}"

PIDS=()
cleanup() {
  for pid in ${PIDS[@]:-}; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
    [ -n "$pid" ] && wait "$pid" 2>/dev/null || true
  done
  # …and by port, because a node started through a command substitution
  # is re-parented to init: a pid this script forgot is a process it can
  # no longer address, while the port still identifies it (the fixed
  # port check at the top is what keeps the sweep specific)
  for pid in $(lsof -ti ":$BROKER_PORT" -sTCP:LISTEN 2>/dev/null); do
    kill "$pid" 2>/dev/null || true
  done
  wait 2>/dev/null || true
}
trap 'cleanup; rm -rf "$WORK"' EXIT

fail() { echo "E2E-P17 FAIL: $*" >&2; exit 1; }
pass() { echo "E2E-P17 PASS: $*"; }

if lsof -i ":$BROKER_PORT" -sTCP:LISTEN > /dev/null 2>&1; then
  fail "port $BROKER_PORT is already in use"
fi

wait_listen() { # $1 = port
  for _ in $(seq 1 60); do
    lsof -i ":$1" -sTCP:LISTEN > /dev/null 2>&1 && return 0
    sleep 0.1
  done
  return 1
}

# The fields of one `label min=.. avg=.. p50=.. p90=.. p99=.. max=.. count=..`
# line, in order. A histogram that is not monotone is a report nobody
# can read, and a count that disagrees with the run is a report nobody
# can trust.
check_histogram() { # $1 = line, $2 = expected count
  local line="$1" want="$2"
  local min p50 p90 p99 max count
  min="$(printf '%s\n' "$line" | grep -o 'min=[0-9]*' | cut -d= -f2)"
  p50="$(printf '%s\n' "$line" | grep -o 'p50=[0-9]*' | cut -d= -f2)"
  p90="$(printf '%s\n' "$line" | grep -o 'p90=[0-9]*' | cut -d= -f2)"
  p99="$(printf '%s\n' "$line" | grep -o 'p99=[0-9]*' | cut -d= -f2)"
  max="$(printf '%s\n' "$line" | grep -o 'max=[0-9]*' | cut -d= -f2)"
  count="$(printf '%s\n' "$line" | grep -o 'count=[0-9]*' | cut -d= -f2)"
  [ "$count" = "$want" ] || fail "histogram counted ${count}, expected $want"
  [ "$min" -le "$p50" ] && [ "$p50" -le "$p90" ] && [ "$p90" -le "$p99" ] && \
    [ "$p99" -le "$max" ] || fail "histogram is not monotone: $line"
}

field() { # $1 = text, $2 = key
  printf '%s\n' "$1" | grep -o "$2=[0-9]*" | head -1 | cut -d= -f2
}

REMOTE="127.0.0.1:$BROKER_PORT"

# ---- the broker everything runs against ---------------------------------
"$EXE" serve --data-dir "$WORK/dd" --listen "$REMOTE" \
  > "$WORK/serve.log" 2>&1 &
BROKER_PID=$!
PIDS+=("$BROKER_PID")
wait_listen "$BROKER_PORT" || fail "broker never listened on $BROKER_PORT"

# ---- 1. produce: exact counts, contiguous offsets, monotone histogram ---
"$EXE" benchmark produce --topic "$TOPIC" --remote "$REMOTE" \
  --records 20000 --record-size 256 --batch-records 512 \
  > "$WORK/produce.out" 2> "$WORK/produce.err" || fail "produce run failed"
RESULT="$(grep '^result ' "$WORK/produce.out")"
[ "$(field "$RESULT" records)" = "20000" ] || fail "produce reported records=$(field "$RESULT" records)"
[ "$(field "$RESULT" base_offset)" = "0" ] || fail "produce base_offset=$(field "$RESULT" base_offset), expected 0"
[ "$(field "$RESULT" end_offset)" = "20000" ] || fail "produce end_offset=$(field "$RESULT" end_offset)"
[ "$(field "$RESULT" bytes)" = "5120000" ] || fail "produce bytes=$(field "$RESULT" bytes), expected 5120000"
[ "$(field "$RESULT" batches)" = "40" ] || fail "produce batches=$(field "$RESULT" batches), expected 40 (20000/512)"
THROUGH="$(grep '^throughput ' "$WORK/produce.out")"
[ "$(field "$THROUGH" records_per_sec)" -gt 0 ] || fail "throughput reported zero"
check_histogram "$(grep '^batch_latency_us ' "$WORK/produce.out")" 40
pass "1: produce reported exact counts, a contiguous range, and a monotone histogram"

# ---- 2. verified consume: what went in is what came back out -----------
"$EXE" benchmark consume --topic "$TOPIC" --remote "$REMOTE" --verify \
  > "$WORK/consume.out" 2> "$WORK/consume.err" || fail "verified consume failed"
CREAD="$(grep '^result ' "$WORK/consume.out")"
[ "$(field "$CREAD" records)" = "20000" ] || fail "consume reported records=$(field "$CREAD" records)"
[ "$(field "$CREAD" bytes)" = "5120000" ] || fail "consume bytes=$(field "$CREAD" bytes), expected 5120000"
[ "$(field "$CREAD" end_offset)" = "20000" ] || fail "consume drained to $(field "$CREAD" end_offset), expected the scan end 20000"
grep -qx 'sequence_ok=true' "$WORK/consume.out" || fail "sequence verification failed (value headers vs offsets)"
pass "2: verified consume read back exactly what was produced, to the server's scan end"

# ---- 3. the same round trip on the local path ---------------------------
"$EXE" benchmark produce --topic "$TOPIC" --data-dir "$WORK/local" \
  --records 20000 --record-size 256 --batch-records 512 \
  > "$WORK/lproduce.out" 2> "$WORK/lproduce.err" || fail "local produce failed"
LRESULT="$(grep '^result ' "$WORK/lproduce.out")"
[ "$(field "$LRESULT" records)" = "20000" ] || fail "local produce records=$(field "$LRESULT" records)"
[ "$(field "$LRESULT" base_offset)" = "0" ] || fail "local produce base_offset=$(field "$LRESULT" base_offset)"
"$EXE" benchmark consume --topic "$TOPIC" --data-dir "$WORK/local" --verify \
  > "$WORK/lconsume.out" 2> "$WORK/lconsume.err" || fail "local verified consume failed"
LCREAD="$(grep '^result ' "$WORK/lconsume.out")"
[ "$(field "$LCREAD" records)" = "20000" ] || fail "local consume records=$(field "$LCREAD" records)"
[ "$(field "$LCREAD" bytes)" = "5120000" ] || fail "local consume bytes=$(field "$LCREAD" bytes)"
grep -qx 'sequence_ok=true' "$WORK/lconsume.out" || fail "local sequence verification failed"
pass "3: the local round trip carries the same counts and the same integrity"

# ---- 4. latency: every sample produced, consumed, and monotone ----------
"$EXE" benchmark latency --topic "$LAT_TOPIC" --remote "$REMOTE" \
  --samples 30 --record-size 256 \
  > "$WORK/latency.out" 2> "$WORK/latency.err" || fail "latency run failed"
LRES="$(grep '^result ' "$WORK/latency.out")"
[ "$(field "$LRES" samples)" = "30" ] || fail "latency samples=$(field "$LRES" samples)"
[ "$(field "$LRES" produced)" = "30" ] || fail "latency produced=$(field "$LRES" produced)"
[ "$(field "$LRES" consumed)" = "30" ] || fail "latency consumed=$(field "$LRES" consumed)"
grep -q 'sequence_ok=true' "$WORK/latency.out" || fail "latency sequence verification failed"
ACK_LINE="$(grep '^produce_ack_us ' "$WORK/latency.out")"
E2E_LINE="$(grep '^e2e_us ' "$WORK/latency.out")"
check_histogram "$ACK_LINE" 30
check_histogram "$E2E_LINE" 30
# e2e contains the produce ack; a report where visibility beats the ack
# it includes is a report about some other run
[ "$(field "$E2E_LINE" p50)" -ge "$(field "$ACK_LINE" p50)" ] || \
  fail "e2e p50 ($(field "$E2E_LINE" p50)) is below produce-ack p50 ($(field "$ACK_LINE" p50))"
pass "4: every latency sample was produced, consumed, and verified; both histograms are monotone"

# ---- 5. the P16 regression guard: one open per topic, not per request ---
OPENED="$(grep -c '^opened' "$WORK/serve.log" || true)"
[ "$OPENED" = "2" ] || fail "the broker opened logs $OPENED times; expected exactly 2 (one per topic — a per-request open regression shows up here)"
grep -c "^opened $TOPIC\[0\]" "$WORK/serve.log" | grep -qx 1 || fail "topic $TOPIC was opened more than once"
grep -c "^opened $LAT_TOPIC\[0\]" "$WORK/serve.log" | grep -qx 1 || fail "topic $LAT_TOPIC was opened more than once"
pass "5: through produce, consume, and latency the broker opened each topic's log exactly once"

# ---- 6. an oversize record is refused by name, broker unaffected -------
if "$EXE" benchmark produce --topic "$TOPIC" --remote "$REMOTE" \
  --records 10 --record-size 5000000 \
  > "$WORK/oversize.out" 2> "$WORK/oversize.err"; then
  fail "an over-limit record size was accepted"
fi
grep -q 'per-field limit' "$WORK/oversize.err" || \
  fail "the oversize refusal does not name the limit: $(cat "$WORK/oversize.err")"
"$EXE" benchmark produce --topic "$TOPIC" --remote "$REMOTE" \
  --records 10 --record-size 128 > "$WORK/after.out" 2>/dev/null || \
  fail "the broker stopped serving after a refused oversize record"
grep -q 'result records=10' "$WORK/after.out" || fail "the follow-up produce did not report 10 records"
pass "6: an oversize record is refused by name in the producer, and the broker keeps serving"

echo "E2E-P17: all green"
