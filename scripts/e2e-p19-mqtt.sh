#!/usr/bin/env bash
# E2E-P19: streams and passes — a subscription source, a publish sink,
# and the one-shot sources that must not change behavior.
#
# The peer is scripts/mqtt_test_broker.py, an independent MQTT 3.1.1
# implementation (same spirit as mfs_probe.py): the assertions are about
# bytes on the wire, not about what the client believes it sent.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXE="${MOONFLUX_EXE:-$ROOT/_build/native/debug/build/apps/cli/cli.exe}"
[ -x "$EXE" ] || EXE="$ROOT/_build/native/release/build/apps/cli/cli.exe"
[ -x "$EXE" ] || {
  echo "cli executable not found; run: moon build --target native" >&2
  exit 1
}

WORK="$(mktemp -d /tmp/moonflux-p19-mqtt.XXXXXX)"
BROKER_PORT="${MOONFLUX_P19_BROKER_PORT:-19801}"
CLOSED_PORT="${MOONFLUX_P19_CLOSED_PORT:-19899}"
BROKER_PID=""
RUN_PID=""

cleanup() {
  for pid in "$RUN_PID" "$BROKER_PID"; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
    [ -n "$pid" ] && wait "$pid" 2>/dev/null || true
  done
  # …and by port, because a fixture started through a command
  # substitution is re-parented to init and its pid is unreachable
  for port in "$BROKER_PORT"; do
    for pid in $(lsof -ti ":$port" -sTCP:LISTEN 2>/dev/null); do
      kill "$pid" 2>/dev/null || true
    done
  done
  wait 2>/dev/null || true
}
trap 'cleanup; rm -rf "$WORK"' EXIT

fail() { echo "E2E-P19 FAIL: $1" >&2; exit 1; }
pass() { echo "E2E-P19 PASS: $1"; }

for port in "$BROKER_PORT" "$CLOSED_PORT"; do
  if lsof -i ":$port" -sTCP:LISTEN >/dev/null 2>&1; then
    fail "port $port is already in use"
  fi
done

wait_listen() { # $1 = port
  for _ in $(seq 1 60); do
    lsof -i ":$1" -sTCP:LISTEN >/dev/null 2>&1 && return 0
    sleep 0.1
  done
  return 1
}

start_broker() { # rest = broker flags
  python3 "$ROOT/scripts/mqtt_test_broker.py" --listen "127.0.0.1:$BROKER_PORT" "$@" \
    > "$WORK/broker.log" 2>&1 &
  BROKER_PID=$!
  wait_listen "$BROKER_PORT" || fail "the test broker never listened"
}

write_spec() { # $1 = path, $2 = source json, $3 = sink json
  printf '{"apiVersion":"moonflux.io/v1alpha1","kind":"Pipeline","metadata":{"name":"p19"},"spec":{"source":%s,"topic":{"name":"mqtt-events"},"sink":%s}}\n' \
    "$2" "$3" > "$1"
}

# ---- 1. the subscription source streams, and does not exit ----------
write_spec "$WORK/in.json" \
  "{\"type\":\"mqtt\",\"url\":\"mqtt://127.0.0.1:$BROKER_PORT/sensors\"}" \
  "{\"type\":\"stdout\"}"
"$EXE" pipeline apply -f "$WORK/in.json" --data-dir "$WORK/stream" > /dev/null ||
  fail "apply of the streaming spec failed"
start_broker --publish sensors:alpha --publish sensors:beta --publish sensors:gamma \
  --facts "$WORK/facts.txt" --received "$WORK/received.txt"

"$EXE" pipeline run --data-dir "$WORK/stream" > "$WORK/run.out" 2> "$WORK/run.err" &
RUN_PID=$!
for _ in $(seq 1 80); do
  grep -q '^gamma$' "$WORK/run.out" 2>/dev/null && break
  sleep 0.25
done
[ "$(cat "$WORK/run.out")" = "$(printf 'alpha\nbeta\ngamma')" ] ||
  fail "the stream did not deliver the messages: $(cat "$WORK/run.out")"
kill -0 "$RUN_PID" 2>/dev/null ||
  fail "the subscription run exited — a stream is not a pass: $(cat "$WORK/run.err")"
"$EXE" consume --topic mqtt-events --data-dir "$WORK/stream" 2>/dev/null | cut -f4- > "$WORK/topic.out"
[ "$(cat "$WORK/topic.out")" = "$(printf 'alpha\nbeta\ngamma')" ] ||
  fail "the topic holds: $(cat "$WORK/topic.out")"
kill "$RUN_PID" 2>/dev/null || true
wait "$RUN_PID" 2>/dev/null || true
RUN_PID=""
pass "1: the mqtt source streamed three messages to the sink and the topic, and stayed subscribed"

# ---- 2. the wire says what we mean ----------------------------------
grep -q '^connect client_id=moonflux-source-' "$WORK/facts.txt" ||
  fail "CONNECT facts: $(cat "$WORK/facts.txt")"
grep -q 'clean=1' "$WORK/facts.txt" || fail "clean-session flag missing"
grep -q '^subscribe topic=sensors$' "$WORK/facts.txt" ||
  fail "SUBSCRIBE facts: $(cat "$WORK/facts.txt")"
pass "2: the broker saw CONNECT (clean session, role-named client) and SUBSCRIBE sensors"

# ---- 3. the publish sink --------------------------------------------
printf 'out-one\nout-two\n' > "$WORK/out.txt"
write_spec "$WORK/out-spec.json" \
  "{\"type\":\"file\",\"path\":\"$WORK/out.txt\"}" \
  "{\"type\":\"mqtt\",\"url\":\"mqtt://127.0.0.1:$BROKER_PORT/commands\"}"
"$EXE" pipeline apply -f "$WORK/out-spec.json" --data-dir "$WORK/publish" > /dev/null ||
  fail "apply of the publishing spec failed"
"$EXE" pipeline run --data-dir "$WORK/publish" > /dev/null 2> "$WORK/pub.err" ||
  fail "the publishing run failed: $(cat "$WORK/pub.err")"
for _ in $(seq 1 40); do
  [ "$(wc -l < "$WORK/received.txt" 2>/dev/null || echo 0)" = "2" ] && break
  sleep 0.25
done
[ "$(cat "$WORK/received.txt" 2>/dev/null)" = "$(printf 'out-one\nout-two')" ] ||
  fail "the broker received: $(cat "$WORK/received.txt" 2>/dev/null)"
grep -q '^publish topic=commands$' "$WORK/facts.txt" ||
  fail "the broker never saw the publish topic: $(grep -c publish "$WORK/facts.txt" || true)"
pass "3: the sink published both records to commands, and the broker decoded them"

# ---- 4. refusals stay refusals --------------------------------------
write_spec "$WORK/bad.json" \
  "{\"type\":\"mqtt\",\"url\":\"mqtt://hostonly\"}" \
  "{\"type\":\"stdout\"}"
if "$EXE" pipeline apply -f "$WORK/bad.json" --data-dir "$WORK/bad" > "$WORK/bad.out" 2>&1; then
  fail "a topicless mqtt url was accepted at apply"
fi
grep -q 'mqtt urls look like' "$WORK/bad.out" ||
  fail "apply refusal does not name the shape: $(cat "$WORK/bad.out")"
write_spec "$WORK/down.json" \
  "{\"type\":\"mqtt\",\"url\":\"mqtt://127.0.0.1:$CLOSED_PORT/x\"}" \
  "{\"type\":\"stdout\"}"
"$EXE" pipeline apply -f "$WORK/down.json" --data-dir "$WORK/down" > /dev/null ||
  fail "apply of the dead-broker spec failed"
if "$EXE" pipeline run --data-dir "$WORK/down" > "$WORK/down.out" 2> "$WORK/down.err"; then
  fail "a dead broker produced a successful run"
fi
grep -q "connect" "$WORK/down.err" ||
  fail "the dead-broker error does not name the connect: $(cat "$WORK/down.err")"
pass "4: bad urls are refused at apply; a dead broker is a structured error"

# ---- 5. the one-shot sources kept their contract --------------------
printf 'one\ntwo\n' > "$WORK/pass.txt"
write_spec "$WORK/pass.json" \
  "{\"type\":\"file\",\"path\":\"$WORK/pass.txt\"}" \
  "{\"type\":\"stdout\"}"
"$EXE" pipeline apply -f "$WORK/pass.json" --data-dir "$WORK/pass" > /dev/null ||
  fail "apply of the one-shot spec failed"
"$EXE" pipeline run --data-dir "$WORK/pass" > "$WORK/pass.out" 2> "$WORK/pass.err" ||
  fail "the one-shot run failed: $(cat "$WORK/pass.err")"
[ "$(cat "$WORK/pass.out")" = "$(printf 'one\ntwo')" ] ||
  fail "one-shot output: $(cat "$WORK/pass.out")"
pass "5: a one-shot source still delivers once and exits 0"

echo "E2E-P19: all green"
