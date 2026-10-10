#!/bin/bash
# E2E-P30: the connector examples (examples/sdf/09..11), run end to end.
#
# These are the external-data ports: SDF reaches the outside world through
# separately deployed connectors (its dataflow.yaml only ever names topics),
# while a moonflux spec names the connector itself. Three cases prove that
# shape against independent test peers, so nothing here needs the network:
#
#   1  HTTP source     car-processing / ny-transit's ingest half: a local
#                      http.server serves the fixture, the pipeline fetches
#                      it, filters, and the log keeps what arrived
#   2  MQTT source     helsinki-transit's ingest half: the repo's own MQTT
#                      3.1.1 test broker pushes three events on SUBSCRIBE
#   3  MQTT wire       the broker's facts file says CONNECT (clean) and
#                      SUBSCRIBE transit — the source really speaks MQTT
#   4  Kafka in        a file becomes three records on an independent
#                      Kafka-speaking broker (acks=1, CRC valid)
#   5  Kafka bridge    kafka -> filter -> kafka across two brokers: only
#                      the paid orders reach the second one
#   6  Kafka out       the second broker's received file is the assertion,
#                      not our own client's opinion
#   7  HTTP poll       interval_ms makes the source a poller: Quiet, never
#                      Exhausted, and every poll is its own batch
#
# What the cases deliberately do not fake: SDF's helsinki-transit computes
# a per-vehicle average speed, which needs durable keyed state we do not
# have (see docs/sdf-examples-port.md §4); the case stops at the ingest
# boundary and says so in its README.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
EXE="${MOONFLUX_EXE:-$ROOT/_build/native/debug/build/apps/cli/cli.exe}"
EXAMPLES="$ROOT/examples/sdf"
WORK="$(mktemp -d /tmp/moonflux-p30-connectors.XXXXXX)"

HTTP_PORT="${MOONFLUX_P30_HTTP_PORT:-20011}"
MQTT_PORT="${MOONFLUX_P30_MQTT_PORT:-20012}"
KAFKA_IN_PORT="${MOONFLUX_P30_KAFKA_IN_PORT:-20013}"
KAFKA_OUT_PORT="${MOONFLUX_P30_KAFKA_OUT_PORT:-20014}"
TOPIC_IN="${MOONFLUX_P30_TOPIC_IN:-orders-in}"
TOPIC_OUT="${MOONFLUX_P30_TOPIC_OUT:-orders-paid}"

PIDS=()
RUN_PID=""

cleanup() {
  [ -n "$RUN_PID" ] && kill "$RUN_PID" 2>/dev/null
  for pid in "${PIDS[@]:-}"; do kill "$pid" 2>/dev/null; done
  # ports are the fallback: anything we started but lost track of
  for port in "$HTTP_PORT" "$MQTT_PORT" "$KAFKA_IN_PORT" "$KAFKA_OUT_PORT"; do
    for pid in $(lsof -ti ":$port" -sTCP:LISTEN 2>/dev/null); do kill "$pid" 2>/dev/null; done
  done
  rm -rf "$WORK"
}
trap cleanup EXIT

fail() { echo "E2E-P30-CONNECTOR-EXAMPLES FAIL: $*" >&2; exit 1; }
pass() { echo "E2E-P30-CONNECTOR-EXAMPLES PASS: $*"; }

wait_listen() { # $1 = port
  for _ in $(seq 1 60); do
    lsof -i ":$1" -sTCP:LISTEN > /dev/null 2>&1 && return 0
    sleep 0.1
  done
  return 1
}

check() { # $1 = label, $2 = actual file, $3 = expected file
  if ! diff -u "$3" "$2" > "$WORK/diff.txt" 2>&1; then
    echo "--- expected vs actual ($1) ---" >&2
    cat "$WORK/diff.txt" >&2
    fail "$1: output does not match $3"
  fi
}

count_lines() { # $1 = file; a file the peer has not created yet counts as 0
  if [ -f "$1" ]; then wc -l < "$1" | tr -d ' '; else echo 0; fi
}

for port in "$HTTP_PORT" "$MQTT_PORT" "$KAFKA_IN_PORT" "$KAFKA_OUT_PORT"; do
  lsof -i ":$port" -sTCP:LISTEN > /dev/null 2>&1 && fail "port $port is already in use"
done
[ -x "$EXE" ] || fail "cli binary not found at $EXE (run: moon build --target native)"
[ -f "$ROOT/_build/wasm/debug/build/apps/operator-filter/operator-filter.wasm" ] ||
  fail "missing operator-filter.wasm — run: scripts/build-operators.sh"

# ---- 1. HTTP source: the ingest half of car-processing / ny-transit ----
SRV="$WORK/www"
mkdir -p "$SRV"
cp "$EXAMPLES/09-http-source/cars.jsonl" "$SRV/cars.jsonl"
(cd "$SRV" && python3 -m http.server "$HTTP_PORT" > "$WORK/http.log" 2>&1) &
PIDS+=("$!")
wait_listen "$HTTP_PORT" || { cat "$WORK/http.log"; fail "the local http.server never listened"; }
D="$WORK/d09"
"$EXE" pipeline run --data-dir "$D" --spec "$EXAMPLES/09-http-source/spec.json" \
  > "$WORK/09.out" 2> "$WORK/09.err" || { cat "$WORK/09.err"; fail "case 9: run failed"; }
check "9 http source (filtered)" "$WORK/09.out" "$EXAMPLES/09-http-source/expected.txt"
# the log keeps what the connector fetched, not what the filter let through
"$EXE" consume --topic sdf-09-cars --from 0 --data-dir "$D" 2> "$WORK/09c.err" \
  | cut -f4 > "$WORK/09-topic.out" || { cat "$WORK/09c.err"; fail "case 9: consume failed"; }
check "9 http source (topic holds the raw fetch)" "$WORK/09-topic.out" "$EXAMPLES/09-http-source/expected-topic.txt"
grep -q "GET /cars.jsonl" "$WORK/http.log" ||
  { cat "$WORK/http.log"; fail "case 9: the server never saw the GET the source claims to have made"; }
pass "1. http source: one GET delivered four records, the filter kept the Fords, the log kept all four"

# ---- 2. MQTT source: the ingest half of helsinki-transit ---------------
PUBLISH=()
while read -r line; do PUBLISH+=(--publish "transit:$line"); done < "$EXAMPLES/10-mqtt-transit/events.jsonl"
python3 "$ROOT/scripts/mqtt_test_broker.py" --listen "127.0.0.1:$MQTT_PORT" \
  "${PUBLISH[@]}" --facts "$WORK/mqtt-facts.txt" --received "$WORK/mqtt-received.txt" \
  > "$WORK/mqtt.log" 2>&1 &
PIDS+=("$!")
wait_listen "$MQTT_PORT" || { cat "$WORK/mqtt.log"; fail "the MQTT test broker never listened"; }
D="$WORK/d10"
"$EXE" pipeline run --data-dir "$D" --spec "$EXAMPLES/10-mqtt-transit/spec.json" \
  > "$WORK/10.out" 2> "$WORK/10.err" &
RUN_PID=$!
for _ in $(seq 1 80); do
  [ "$(count_lines "$WORK/10.out")" -ge 3 ] && break
  sleep 0.25
done
kill -0 "$RUN_PID" 2>/dev/null ||
  { cat "$WORK/10.err"; fail "case 10: the subscription run exited — a stream is not a pass"; }
check "10 mqtt source" "$WORK/10.out" "$EXAMPLES/10-mqtt-transit/expected.txt"
"$EXE" consume --topic sdf-10-transit --from 0 --data-dir "$D" 2> "$WORK/10c.err" \
  | cut -f4 > "$WORK/10-topic.out" || { cat "$WORK/10c.err"; fail "case 10: consume failed"; }
check "10 mqtt source (topic)" "$WORK/10-topic.out" "$EXAMPLES/10-mqtt-transit/expected.txt"
kill "$RUN_PID" 2>/dev/null; wait "$RUN_PID" 2>/dev/null; RUN_PID=""
pass "2. mqtt source: three events arrived in order and stayed subscribed, and the topic holds them"

# ---- 3. the MQTT wire says what we mean --------------------------------
grep -q '^connect client_id=moonflux-source-' "$WORK/mqtt-facts.txt" ||
  { cat "$WORK/mqtt-facts.txt"; fail "case 10: no CONNECT fact from the broker"; }
grep -q 'clean=1' "$WORK/mqtt-facts.txt" || fail "case 10: the CONNECT did not ask for a clean session"
grep -q '^subscribe topic=transit$' "$WORK/mqtt-facts.txt" ||
  { cat "$WORK/mqtt-facts.txt"; fail "case 10: the broker never saw SUBSCRIBE transit"; }
pass "3. mqtt wire: the broker decoded CONNECT (clean session) and SUBSCRIBE transit"

# ---- 4. Kafka inbound: file -> external broker -------------------------
python3 "$ROOT/scripts/kafka_test_broker.py" --listen "127.0.0.1:$KAFKA_IN_PORT" \
  --topic "$TOPIC_IN" --facts "$WORK/kafka-in-facts.txt" --received "$WORK/kafka-in-received.txt" \
  > "$WORK/kafka-in.log" 2>&1 &
PIDS+=("$!")
wait_listen "$KAFKA_IN_PORT" || { cat "$WORK/kafka-in.log"; fail "the inbound Kafka broker never listened"; }
"$EXE" pipeline run --data-dir "$WORK/d11a" --spec "$EXAMPLES/11-kafka-bridge/seed-spec.json" \
  > /dev/null 2> "$WORK/11a.err" || { cat "$WORK/11a.err"; fail "case 11: the seeding run failed"; }
for _ in $(seq 1 40); do
  [ "$(count_lines "$WORK/kafka-in-received.txt")" -ge 3 ] && break
  sleep 0.25
done
[ "$(cut -f2 "$WORK/kafka-in-received.txt" 2>/dev/null)" = "$(cat "$EXAMPLES/11-kafka-bridge/orders.jsonl")" ] ||
  { cat "$WORK/kafka-in-received.txt" 2>/dev/null; fail "case 11: the broker did not receive the three orders verbatim"; }
pass "4. kafka in: the file source delivered three orders to an independent broker"

# ---- 5. Kafka bridge: kafka -> filter -> kafka -------------------------
python3 "$ROOT/scripts/kafka_test_broker.py" --listen "127.0.0.1:$KAFKA_OUT_PORT" \
  --topic "$TOPIC_OUT" --received "$WORK/kafka-out-received.txt" \
  > "$WORK/kafka-out.log" 2>&1 &
PIDS+=("$!")
wait_listen "$KAFKA_OUT_PORT" || { cat "$WORK/kafka-out.log"; fail "the outbound Kafka broker never listened"; }
"$EXE" pipeline run --data-dir "$WORK/d11b" --spec "$EXAMPLES/11-kafka-bridge/bridge-spec.json" \
  > "$WORK/11b.out" 2> "$WORK/11b.err" &
RUN_PID=$!
for _ in $(seq 1 80); do
  [ "$(count_lines "$WORK/kafka-out-received.txt")" -ge 2 ] && break
  sleep 0.25
done
kill -0 "$RUN_PID" 2>/dev/null ||
  { cat "$WORK/11b.err"; fail "case 11: the bridge run exited — the Kafka source is a stream"; }
sleep 0.5
kill "$RUN_PID" 2>/dev/null; wait "$RUN_PID" 2>/dev/null; RUN_PID=""
cut -f2 "$WORK/kafka-out-received.txt" > "$WORK/11b-paid.out"
check "11 kafka bridge" "$WORK/11b-paid.out" "$EXAMPLES/11-kafka-bridge/expected-paid.txt"
pass "5. kafka bridge: kafka -> filter -> kafka carried the paid orders and nothing else"

# ---- 6. the produce side spoke Kafka, not something shaped like it -----
grep -qE "^produce topic=$TOPIC_IN partition=0 acks=1 records=3 base=[0-9]+ crc=ok codec=none" \
  "$WORK/kafka-in-facts.txt" ||
  { cat "$WORK/kafka-in-facts.txt"; fail "case 11: the produce facts are not a valid batch (acks=1, crc ok)"; }
pass "6. kafka out: the broker's own facts confirm acks=1 and a CRC-valid batch"

# ---- 7. the same source, polling (interval_ms) -------------------------
# SDF's http-source re-fetches on an interval. Ours does too now, and the
# assertion that matters is the pull contract: a poller says Quiet ("not
# now") and never Exhausted ("never"), so the run stays alive and keeps
# delivering. Re-fetching an unchanged body re-delivers the same records —
# deduplication is the reader's problem, as for any external poller.
D="$WORK/d09p"
"$EXE" pipeline run --data-dir "$D" --spec "$EXAMPLES/09-http-source/spec-poll.json"   > "$WORK/09p.out" 2> "$WORK/09p.err" &
RUN_PID=$!
for _ in $(seq 1 40); do
  [ "$(count_lines "$WORK/09p.out")" -ge 4 ] && break
  sleep 0.25
done
kill -0 "$RUN_PID" 2>/dev/null ||
  { cat "$WORK/09p.err"; fail "case 9 poll: the poller exited — a poller that exhausts is a one-shot"; }
[ "$(count_lines "$WORK/09p.out")" -ge 4 ] ||
  { cat "$WORK/09p.out"; fail "case 9 poll: two 200ms polls should have delivered four filtered records"; }
kill "$RUN_PID" 2>/dev/null; wait "$RUN_PID" 2>/dev/null; RUN_PID=""
# each poll appends its own batch: two polls of a four-line body
POLLED="$("$EXE" consume --topic sdf-09-cars-polled --from 0 --data-dir "$D" 2>/dev/null | wc -l | tr -d ' ')"
[ "$POLLED" -ge 8 ] || fail "case 9 poll: the topic holds $POLLED records, expected at least two four-record polls"
pass "7. http poller: re-fetches on the interval, never exhausts, and every poll is its own batch"

echo "E2E-P30-CONNECTOR-EXAMPLES: 7 legs green (3 connector applications)"
