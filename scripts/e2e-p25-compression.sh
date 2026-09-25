#!/bin/bash
# E2E-P25: batch compression — the DEFLATE codec and the Kafka
# connector's gzip support, anchored on BOTH sides by Python's zlib.
#
#    1. sink with ?compression=gzip: the broker's python inflater
#       decompresses our batch and verifies the records byte-for-byte
#       (OUR compressor judged by THEIR inflater)
#    2. broker --compress-gzip: every stored batch is rebuilt with the
#       gzip codec, and a moonflux source reads it back byte-identical
#       (THEIR compressor judged by OUR inflater)
#    3. the plain pipeline is unchanged: uncompressed in, uncompressed
#       out, records identical (the P20 default still holds)
#    4. an unknown compression in a kafka url is refused at apply time
#
# The offline half of the anchor lives in core/codec_test, where
# Python's zlib output (three containers, two levels) is inflated by
# our decoder against generated golden vectors.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXE="${MOONFLUX_EXE:-$ROOT/_build/native/debug/build/apps/cli/cli.exe}"
[ -x "$EXE" ] || EXE="$ROOT/_build/native/release/build/apps/cli/cli.exe"
[ -x "$EXE" ] || {
  echo "cli executable not found; run: moon build --target native" >&2
  exit 1
}

WORK="$(mktemp -d /tmp/moonflux-p25-compression.XXXXXX)"
BROKER_PORT="${MOONFLUX_P25_BROKER_PORT:-19911}"
GZIP_PORT="${MOONFLUX_P25_GZIP_PORT:-19912}"
TOPIC="events"
BROKER_PID=""
RUN_PID=""

cleanup() {
  for pid in "$RUN_PID" "$BROKER_PID"; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
    [ -n "$pid" ] && wait "$pid" 2>/dev/null || true
  done
  for port in "$BROKER_PORT" "$GZIP_PORT"; do
    for pid in $(lsof -ti ":$port" -sTCP:LISTEN 2>/dev/null); do
      kill "$pid" 2>/dev/null || true
    done
  done
  wait 2>/dev/null || true
}
trap 'cleanup; if [ "${MOONFLUX_KEEP:-0}" = "1" ]; then echo "keeping $WORK"; else rm -rf "$WORK"; fi' EXIT

fail() { echo "E2E-P25 FAIL: $1" >&2; exit 1; }
pass() { echo "E2E-P25 PASS: $1"; }

for port in "$BROKER_PORT" "$GZIP_PORT"; do
  if lsof -i ":$port" -sTCP:LISTEN >/dev/null 2>&1; then
    fail "port $port is already in use"
  fi
done

wait_listen() {
  for _ in $(seq 1 60); do
    lsof -i ":$1" -sTCP:LISTEN >/dev/null 2>&1 && return 0
    sleep 0.1
  done
  return 1
}

start_broker() { # $1 = port, rest = flags
  local port="$1"
  shift
  python3 "$ROOT/scripts/kafka_test_broker.py" --listen "127.0.0.1:$port" \
    --topic "$TOPIC" "$@" > "$WORK/broker-$port.log" 2>&1 &
  BROKER_PID=$!
  wait_listen "$port" || fail "the test broker never listened on $port"
}

printf 'alpha-1\nalpha-2\nalpha-3\nbeta-1\nbeta-2\n' > "$WORK/in.txt"
write_spec() { # $1 = path, $2 = name, $3 = source json, $4 = sink json
  printf '{"apiVersion":"moonflux.io/v1alpha1","kind":"Pipeline","metadata":{"name":"%s"},"spec":{"source":%s,"topic":{"name":"kafka-events"},"sink":%s}}\n' \
    "$2" "$3" "$4" > "$1"
}

# ---- 1. our compressor, judged by python's inflater ----------------------
start_broker "$BROKER_PORT" --facts "$WORK/facts.txt" --received "$WORK/received.txt"
write_spec "$WORK/sink.json" p25-sink \
  "{\"type\":\"file\",\"path\":\"$WORK/in.txt\"}" \
  "{\"type\":\"kafka\",\"url\":\"kafka://127.0.0.1:$BROKER_PORT/events?compression=gzip\"}"
"$EXE" pipeline apply --data-dir "$WORK/data" --file "$WORK/sink.json" > /dev/null \
  || fail "apply of the gzip sink spec failed"
"$EXE" pipeline run --data-dir "$WORK/data" > "$WORK/run1.log" 2>&1 \
  || fail "the gzip sink run failed"
grep -qE "records=[0-9]+ base=[0-9]+ crc=ok codec=gzip" "$WORK/facts.txt" \
  || { cat "$WORK/facts.txt"; fail "the broker did not record a gzip batch"; }
COUNT="$(grep -c 'alpha' "$WORK/received.txt" || true)"
[ "$COUNT" -ge 3 ] || { cat "$WORK/received.txt"; fail "the broker's inflater did not see our records"; }
grep -q "beta-2" "$WORK/received.txt" \
  || fail "the broker's inflater saw truncated records"
pass "1: our gzip batch was inflated by python's zlib — every record intact"

# ---- 2. python's compressor, judged by our inflater ----------------------
BROKER2_PORT="$GZIP_PORT"
# leg 1's broker still holds BROKER_PORT: retire it before moving on
kill "$BROKER_PID" 2>/dev/null || true
wait "$BROKER_PID" 2>/dev/null || true
BROKER_PID=""
python3 "$ROOT/scripts/kafka_test_broker.py" --listen "127.0.0.1:$BROKER2_PORT" \
  --topic "$TOPIC" --compress-gzip --received "$WORK/received2.txt" \
  > "$WORK/broker-$BROKER2_PORT.log" 2>&1 &
BROKER_PID=""
BROKER2_PID=$!
RUN_PID=""
if ! lsof -i ":$BROKER2_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  for _ in $(seq 1 60); do
    lsof -i ":$BROKER2_PORT" -sTCP:LISTEN >/dev/null 2>&1 && break
    sleep 0.1
  done
fi
lsof -i ":$BROKER2_PORT" -sTCP:LISTEN >/dev/null 2>&1 \
  || fail "the compressing broker never listened"
# records land compressed: an uncompressed sink writes them, the broker
# stores them rebuilt with codec 1
write_spec "$WORK/sink2.json" p25-sink2 \
  "{\"type\":\"file\",\"path\":\"$WORK/in.txt\"}" \
  "{\"type\":\"kafka\",\"url\":\"kafka://127.0.0.1:$BROKER2_PORT/events\"}"
"$EXE" pipeline apply --data-dir "$WORK/data2" --file "$WORK/sink2.json" > /dev/null \
  || fail "apply of the plain sink spec failed"
"$EXE" pipeline run --data-dir "$WORK/data2" > "$WORK/run2.log" 2>&1 \
  || fail "the plain sink run failed"
# now read them back through a source: our inflater meets python's gzip
write_spec "$WORK/src.json" p25-src \
  "{\"type\":\"kafka\",\"url\":\"kafka://127.0.0.1:$BROKER2_PORT/events\"}" \
  "{\"type\":\"stdout\"}"
"$EXE" pipeline apply --data-dir "$WORK/data3" --file "$WORK/src.json" > /dev/null \
  || fail "apply of the source spec failed"
"$EXE" pipeline run --data-dir "$WORK/data3" > "$WORK/out.txt" 2>"$WORK/run3.err" &
RUN_PID=$!
GOT=""
for _ in $(seq 1 60); do
  if grep -q "beta-2" "$WORK/out.txt" 2>/dev/null; then GOT=yes; break; fi
  sleep 0.25
done
kill "$RUN_PID" 2>/dev/null || true
wait "$RUN_PID" 2>/dev/null || true
RUN_PID=""
[ -n "$GOT" ] \
  || { echo "stdout held:"; cat "$WORK/out.txt"; fail "the source run over compressed batches never delivered"; }
for line in alpha-1 alpha-2 alpha-3 beta-1 beta-2; do
  grep -q "^$line\$" "$WORK/out.txt" \
    || { echo "stdout held:"; cat "$WORK/out.txt"; fail "record $line did not survive the compressed round trip"; }
done
pass "2: our inflater read python's gzip batches — every record byte-identical"

# ---- 3. the uncompressed path is unchanged -------------------------------
kill "$BROKER_PID" "$BROKER2_PID" 2>/dev/null || true
wait "$BROKER_PID" "$BROKER2_PID" 2>/dev/null || true
BROKER_PID=""
start_broker "$BROKER_PORT" --facts "$WORK/facts3.txt" --received "$WORK/received3.txt"
write_spec "$WORK/sink3.json" p25-sink3 \
  "{\"type\":\"file\",\"path\":\"$WORK/in.txt\"}" \
  "{\"type\":\"kafka\",\"url\":\"kafka://127.0.0.1:$BROKER_PORT/events\"}"
"$EXE" pipeline apply --data-dir "$WORK/data4" --file "$WORK/sink3.json" > /dev/null \
  || fail "apply of the plain sink (no compression param) failed"
rm -f "$WORK/received3.txt"
"$EXE" pipeline run --data-dir "$WORK/data4" > "$WORK/run4.log" 2>&1 \
  || fail "the plain sink run failed"
if [ ! -f "$WORK/facts3.txt" ]; then
  cat "$WORK/broker-$BROKER_PORT.log" 2>/dev/null
  fail "the leg-3 broker recorded nothing (was it started?)"
fi
grep -qE "records=[0-9]+ base=[0-9]+ crc=ok codec=none" "$WORK/facts3.txt" \
  || { cat "$WORK/facts3.txt"; fail "the default is no longer uncompressed"; }
pass "3: the default stays uncompressed (P20's byte-identical shape unchanged)"

# ---- 4. unknown compression is refused at apply time ---------------------
write_spec "$WORK/bad.json" p25-bad \
  "{\"type\":\"file\",\"path\":\"$WORK/in.txt\"}" \
  "{\"type\":\"kafka\",\"url\":\"kafka://127.0.0.1:$BROKER_PORT/events?compression=lz4\"}"
if "$EXE" pipeline apply --data-dir "$WORK/data5" --file "$WORK/bad.json" > "$WORK/bad.out" 2>&1; then
  fail "an lz4 url was accepted at apply time"
fi
grep -qi "compression\|kafka url" "$WORK/bad.out" \
  || fail "the apply refusal does not mention the compression: $(cat "$WORK/bad.out")"
pass "4: unknown compression codecs are refused at apply time, by name"

echo "E2E-P25 PASS: 4 legs green"
