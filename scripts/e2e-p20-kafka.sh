#!/usr/bin/env bash
# E2E-P20: the Kafka connector — round trip, wire shape, and refusals.
#
# The peer is scripts/kafka_test_broker.py, an independent implementation
# of the pinned Kafka protocol versions (ApiVersions v0, Metadata v1,
# ListOffsets v1, Produce v3, Fetch v4). It verifies the CRC-32C of
# every record batch it is handed and parses the records, so the
# assertions are about bytes on the wire — the same spirit as
# mfs_probe.py and mqtt_test_broker.py.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXE="${MOONFLUX_EXE:-$ROOT/_build/native/debug/build/apps/cli/cli.exe}"
[ -x "$EXE" ] || EXE="$ROOT/_build/native/release/build/apps/cli/cli.exe"
[ -x "$EXE" ] || {
  echo "cli executable not found; run: moon build --target native" >&2
  exit 1
}

WORK="$(mktemp -d /tmp/moonflux-p20-kafka.XXXXXX)"
BROKER_PORT="${MOONFLUX_P20_BROKER_PORT:-19901}"
OLD_PORT="${MOONFLUX_P20_OLD_PORT:-19902}"
CLOSED_PORT="${MOONFLUX_P20_CLOSED_PORT:-19999}"
TOPIC="events"
BROKER_PID=""
RUN_PID=""

cleanup() {
  for pid in "$RUN_PID" "$BROKER_PID"; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
    [ -n "$pid" ] && wait "$pid" 2>/dev/null || true
  done
  for port in "$BROKER_PORT" "$OLD_PORT"; do
    for pid in $(lsof -ti ":$port" -sTCP:LISTEN 2>/dev/null); do
      kill "$pid" 2>/dev/null || true
    done
  done
  wait 2>/dev/null || true
}
trap 'cleanup; rm -rf "$WORK"' EXIT

fail() { echo "E2E-P20 FAIL: $1" >&2; exit 1; }
pass() { echo "E2E-P20 PASS: $1"; }

for port in "$BROKER_PORT" "$OLD_PORT" "$CLOSED_PORT"; do
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

start_broker() { # $1 = port, rest = broker flags
  local port="$1"
  shift
  python3 "$ROOT/scripts/kafka_test_broker.py" --listen "127.0.0.1:$port" \
    --topic "$TOPIC" "$@" > "$WORK/broker-$port.log" 2>&1 &
  BROKER_PID=$!
  wait_listen "$port" || fail "the test broker never listened on $port"
}

write_spec() { # $1 = path, $2 = source json, $3 = sink json
  printf '{"apiVersion":"moonflux.io/v1alpha1","kind":"Pipeline","metadata":{"name":"p20"},"spec":{"source":%s,"topic":{"name":"kafka-events"},"sink":%s}}\n' \
    "$2" "$3" > "$1"
}

# ---- 1. the round trip: file -> kafka -> stdout ----------------------
printf 'alpha\nbeta\ngamma\n' > "$WORK/in.txt"
write_spec "$WORK/out.json" \
  "{\"type\":\"file\",\"path\":\"$WORK/in.txt\"}" \
  "{\"type\":\"kafka\",\"url\":\"kafka://127.0.0.1:$BROKER_PORT/$TOPIC\"}"
"$EXE" pipeline apply -f "$WORK/out.json" --data-dir "$WORK/publish" > /dev/null ||
  fail "apply of the publishing spec failed"
start_broker "$BROKER_PORT" --facts "$WORK/facts.txt" --received "$WORK/received.txt"
"$EXE" pipeline run --data-dir "$WORK/publish" > /dev/null 2> "$WORK/pub.err" ||
  fail "the publishing run failed: $(cat "$WORK/pub.err")"
for _ in $(seq 1 40); do
  [ "$(wc -l < "$WORK/received.txt" 2>/dev/null || echo 0)" = "3" ] && break
  sleep 0.25
done
[ "$(cut -f2 "$WORK/received.txt" 2>/dev/null)" = "$(printf 'alpha\nbeta\ngamma')" ] ||
  fail "the broker received: $(cat "$WORK/received.txt" 2>/dev/null)"

write_spec "$WORK/in-spec.json" \
  "{\"type\":\"kafka\",\"url\":\"kafka://127.0.0.1:$BROKER_PORT/$TOPIC\"}" \
  "{\"type\":\"stdout\"}"
"$EXE" pipeline apply -f "$WORK/in-spec.json" --data-dir "$WORK/consume" > /dev/null ||
  fail "apply of the consuming spec failed"
"$EXE" pipeline run --data-dir "$WORK/consume" > "$WORK/run.out" 2> "$WORK/run.err" &
RUN_PID=$!
for _ in $(seq 1 60); do
  grep -q '^gamma$' "$WORK/run.out" 2>/dev/null && break
  sleep 0.25
done
[ "$(cat "$WORK/run.out")" = "$(printf 'alpha\nbeta\ngamma')" ] ||
  fail "the kafka source delivered: $(cat "$WORK/run.out")"
kill -0 "$RUN_PID" 2>/dev/null ||
  fail "the consuming run exited — a kafka source streams, it is not a pass"
"$EXE" consume --topic kafka-events --data-dir "$WORK/consume" 2>/dev/null | cut -f4- > "$WORK/topic.out"
[ "$(cat "$WORK/topic.out")" = "$(printf 'alpha\nbeta\ngamma')" ] ||
  fail "the moonflux topic holds: $(cat "$WORK/topic.out")"
kill "$RUN_PID" 2>/dev/null || true
wait "$RUN_PID" 2>/dev/null || true
RUN_PID=""
pass "1: file -> kafka -> moonflux round-trips the records, and the source stays streaming"

# ---- 2. the wire says what we mean -----------------------------------
grep -q '^apiversions client_id=moonflux-kafka$' "$WORK/facts.txt" ||
  fail "the broker never saw our ApiVersions probe: $(cat "$WORK/facts.txt")"
grep -q "^metadata topic=$TOPIC$" "$WORK/facts.txt" ||
  fail "the broker never saw our metadata request"
grep -qE "^produce topic=$TOPIC partition=0 acks=1 records=3 base=[0-9]+ crc=ok codec=none" "$WORK/facts.txt" ||
  fail "produce facts: $(grep produce "$WORK/facts.txt")"
pass "2: the broker saw the probe, the metadata topic, and a CRC-valid 3-record batch with acks=1"

# ---- 3. the source's own boundaries ----------------------------------
# from=latest on a populated topic delivers nothing new — an empty
# stdout after a wait is the assertion (the run stays alive, quiet)
write_spec "$WORK/latest.json" \
  "{\"type\":\"kafka\",\"url\":\"kafka://127.0.0.1:$BROKER_PORT/$TOPIC?from=latest\"}" \
  "{\"type\":\"stdout\"}"
"$EXE" pipeline apply -f "$WORK/latest.json" --data-dir "$WORK/latest" > /dev/null ||
  fail "apply of the from=latest spec failed"
"$EXE" pipeline run --data-dir "$WORK/latest" > "$WORK/latest.out" 2> "$WORK/latest.err" &
RUN_PID=$!
sleep 1
[ -s "$WORK/latest.out" ] &&
  fail "from=latest replayed history: $(cat "$WORK/latest.out")"
kill -0 "$RUN_PID" 2>/dev/null || fail "the from=latest run exited instead of waiting quietly"
kill "$RUN_PID" 2>/dev/null || true
wait "$RUN_PID" 2>/dev/null || true
RUN_PID=""
# a partition the broker does not have is a structured error
write_spec "$WORK/part.json" \
  "{\"type\":\"kafka\",\"url\":\"kafka://127.0.0.1:$BROKER_PORT/$TOPIC?partition=2\"}" \
  "{\"type\":\"stdout\"}"
"$EXE" pipeline apply -f "$WORK/part.json" --data-dir "$WORK/part" > /dev/null ||
  fail "apply of the partition spec failed"
if "$EXE" pipeline run --data-dir "$WORK/part" > "$WORK/part.out" 2> "$WORK/part.err"; then
  fail "a nonexistent partition produced a successful run"
fi
grep -q "no partition 2" "$WORK/part.err" ||
  fail "the partition refusal does not say why: $(cat "$WORK/part.err")"
pass "3: from=latest waits quietly, and a missing partition is refused with a reason"

# ---- 4. refusals stay refusals ---------------------------------------
write_spec "$WORK/bad.json" \
  "{\"type\":\"kafka\",\"url\":\"kafka://hostonly\"}" \
  "{\"type\":\"stdout\"}"
if "$EXE" pipeline apply -f "$WORK/bad.json" --data-dir "$WORK/bad" > "$WORK/bad.out" 2>&1; then
  fail "a topicless kafka url was accepted at apply"
fi
grep -q 'kafka urls look like' "$WORK/bad.out" ||
  fail "apply refusal does not name the shape: $(cat "$WORK/bad.out")"
write_spec "$WORK/down.json" \
  "{\"type\":\"kafka\",\"url\":\"kafka://127.0.0.1:$CLOSED_PORT/$TOPIC\"}" \
  "{\"type\":\"stdout\"}"
"$EXE" pipeline apply -f "$WORK/down.json" --data-dir "$WORK/down" > /dev/null ||
  fail "apply of the dead-broker spec failed"
if "$EXE" pipeline run --data-dir "$WORK/down" > "$WORK/down.out" 2> "$WORK/down.err"; then
  fail "a dead broker produced a successful run"
fi
grep -q "connect" "$WORK/down.err" ||
  fail "the dead-broker error does not name the connect: $(cat "$WORK/down.err")"
# a broker that advertises an older Produce ceiling is caught by the probe
start_broker "$OLD_PORT" --produce-version-max 2
write_spec "$WORK/old.json" \
  "{\"type\":\"kafka\",\"url\":\"kafka://127.0.0.1:$OLD_PORT/$TOPIC\"}" \
  "{\"type\":\"stdout\"}"
"$EXE" pipeline apply -f "$WORK/old.json" --data-dir "$WORK/old" > /dev/null ||
  fail "apply of the old-broker spec failed"
if "$EXE" pipeline run --data-dir "$WORK/old" > "$WORK/old.out" 2> "$WORK/old.err"; then
  fail "a broker without Produce v3 produced a successful run"
fi
grep -q "does not support Produce v3" "$WORK/old.err" ||
  fail "the version refusal does not name the pin: $(cat "$WORK/old.err")"
pass "4: bad urls, dead brokers, and old brokers are all refused with reasons"

# ---- 5. the one-shot sources kept their contract --------------------
write_spec "$WORK/pass.json" \
  "{\"type\":\"file\",\"path\":\"$WORK/in.txt\"}" \
  "{\"type\":\"stdout\"}"
"$EXE" pipeline apply -f "$WORK/pass.json" --data-dir "$WORK/pass" > /dev/null ||
  fail "apply of the one-shot spec failed"
"$EXE" pipeline run --data-dir "$WORK/pass" > "$WORK/pass.out" 2> "$WORK/pass.err" ||
  fail "the one-shot run failed: $(cat "$WORK/pass.err")"
[ "$(cat "$WORK/pass.out")" = "$(printf 'alpha\nbeta\ngamma')" ] ||
  fail "one-shot output: $(cat "$WORK/pass.out")"
pass "5: a one-shot source still delivers once and exits 0"

echo "E2E-P20: all green"
