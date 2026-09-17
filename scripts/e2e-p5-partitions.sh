#!/bin/bash
# P5 gate: multi-partition storage — a partition is an independent log.
#
#   1. `topic create --partitions 3` really declares three partitions,
#      and the control plane places each one
#   2. writes to different partitions never cross: each has its own log
#      file, its own offsets, and its own read-back
#   3. a partition's watermarks advance independently (writing to
#      partition 1 does not move partition 0's end)
#   4. the default partition is 0: a client that says nothing about
#      partitions keeps working (every pre-P5 client and script)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXE="${MOONFLUX_EXE:-$ROOT/_build/native/release/build/apps/cli/cli.exe}"
[ -x "$EXE" ] || EXE="$ROOT/_build/native/debug/build/apps/cli/cli.exe"
[ -x "$EXE" ] || { echo "cli executable not found; run: moon build --target native" >&2; exit 1; }

WORK="$(mktemp -d /tmp/moonflux-p5-partitions.XXXXXX)"
SC_PORT="${MOONFLUX_SC_PORT:-19471}"
BROKER_PORT="${MOONFLUX_P5_PART_PORT:-19472}"
TOPIC="${MOONFLUX_P5_TOPIC:-shards}"

SC_PID=""; BROKER_PID=""
cleanup() {
  for pid in "$BROKER_PID" "$SC_PID"; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
    [ -n "$pid" ] && wait "$pid" 2>/dev/null || true
  done
  rm -rf "$WORK"
}
trap cleanup EXIT

fail() { echo "E2E-P5-PARTITIONS FAIL: $*" >&2; exit 1; }
pass() { echo "E2E-P5-PARTITIONS PASS: $*"; }
wait_listen() {
  for _ in $(seq 1 60); do
    lsof -i ":$1" -sTCP:LISTEN > /dev/null 2>&1 && return 0
    sleep 0.1
  done
  return 1
}

mkdir -p "$WORK/sc" "$WORK/broker"
"$EXE" sc --listen "127.0.0.1:$SC_PORT" --data-dir "$WORK/sc" > "$WORK/sc.log" 2>&1 &
SC_PID=$!
wait_listen "$SC_PORT" || { cat "$WORK/sc.log"; fail "sc did not start"; }

# ---- 1. the declaration reaches placement ------------------------------
"$EXE" topic create --name "$TOPIC" --partitions 3 --replication-factor 1 \
  --remote "127.0.0.1:$SC_PORT" > "$WORK/create.log" 2>&1 \
  || { cat "$WORK/create.log"; fail "topic create failed"; }
grep -q '"version": 1' "$WORK/sc/metadata.json" || fail "the declaration was not versioned"

"$EXE" spu --id spu-a --listen "127.0.0.1:$BROKER_PORT" --data-dir "$WORK/broker" \
  --sc "127.0.0.1:$SC_PORT" > "$WORK/spu.log" 2>&1 &
BROKER_PID=$!
wait_listen "$BROKER_PORT" || fail "the data node did not start"

# the node learns its topic from an applied pipeline (as before); the
# control plane places all three partitions of the declared topic
"$EXE" pipeline apply -f /dev/stdin --data-dir "$WORK/broker" <<EOF > /dev/null
{
  "apiVersion": "moonflux.io/v1alpha1",
  "kind": "Pipeline",
  "metadata": { "name": "shards" },
  "spec": {
    "source": { "type": "file", "path": "$WORK/in.txt" },
    "transforms": [],
    "topic": { "name": "$TOPIC" },
    "sink": { "type": "stdout" }
  }
}
EOF
kill "$BROKER_PID" 2>/dev/null || true
wait "$BROKER_PID" 2>/dev/null || true
"$EXE" spu --id spu-a --listen "127.0.0.1:$BROKER_PORT" --data-dir "$WORK/broker" \
  --sc "127.0.0.1:$SC_PORT" >> "$WORK/spu.log" 2>&1 &
BROKER_PID=$!
wait_listen "$BROKER_PORT" || fail "the data node did not come back"

for _ in $(seq 1 60); do
  grep -q "placed $TOPIC\[2\]" "$WORK/sc.log" && break
  sleep 0.25
done
grep -q "placed $TOPIC\[0\]" "$WORK/sc.log" || { cat "$WORK/sc.log"; fail "partition 0 was not placed"; }
grep -q "placed $TOPIC\[1\]" "$WORK/sc.log" || { cat "$WORK/sc.log"; fail "partition 1 was not placed"; }
grep -q "placed $TOPIC\[2\]" "$WORK/sc.log" || { cat "$WORK/sc.log"; fail "partition 2 was not placed"; }
pass "a 3-partition declaration was placed partition by partition"

# ---- 2. per-partition writes and reads ---------------------------------
printf 'zero-a\nzero-b\n' > "$WORK/p0.txt"
printf 'one-a\none-b\n' > "$WORK/p1.txt"
printf 'two-a\ntwo-b\n' > "$WORK/p2.txt"
"$EXE" produce --topic "$TOPIC" --file "$WORK/p0.txt" --partition 0 --remote "127.0.0.1:$BROKER_PORT" > /dev/null \
  || fail "produce to partition 0 failed"
"$EXE" produce --topic "$TOPIC" --file "$WORK/p1.txt" --partition 1 --remote "127.0.0.1:$BROKER_PORT" > /dev/null \
  || fail "produce to partition 1 failed"
"$EXE" produce --topic "$TOPIC" --file "$WORK/p2.txt" --partition 2 --remote "127.0.0.1:$BROKER_PORT" > /dev/null \
  || fail "produce to partition 2 failed"

# P8: each partition is its own segment directory; partition 0 in this
# topic must not hold another partition's records
for p in 0 1 2; do
  DIR="$WORK/broker/topics/$TOPIC/partition-$p"
  [ -d "$DIR" ] || fail "partition $p has no segment directory"
  [ -n "$(ls "$DIR"/*.log 2>/dev/null)" ] || fail "partition $p has no segment"
done
pass "each partition holds its own segments"

for p in 0 1 2; do
  OUT="$("$EXE" consume --topic "$TOPIC" --partition "$p" --remote "127.0.0.1:$BROKER_PORT")"
  case "$p" in
    0) printf 'zero-a\nzero-b\n' > "$WORK/want.txt" ;;
    1) printf 'one-a\none-b\n' > "$WORK/want.txt" ;;
    2) printf 'two-a\ntwo-b\n' > "$WORK/want.txt" ;;
  esac
  printf '%s\n' "$OUT" | cut -f4- > "$WORK/got.txt"
  diff -u "$WORK/want.txt" "$WORK/got.txt" \
    || { cat "$WORK/got.txt"; fail "partition $p returned another partition's records"; }
done
pass "reads never cross partitions (each returns exactly what was written to it)"

# ---- 3. watermarks are per partition -----------------------------------
for p in 0 1 2; do
  OUT="$("$EXE" cluster offsets --topic "$TOPIC" --partition "$p" --remote "127.0.0.1:$BROKER_PORT")"
  [ "$OUT" = "2 2" ] || fail "partition $p watermarks should be 2 2 (got $OUT)"
done
printf 'extra\n' > "$WORK/more.txt"
"$EXE" produce --topic "$TOPIC" --file "$WORK/more.txt" --partition 1 --remote "127.0.0.1:$BROKER_PORT" > /dev/null \
  || fail "the extra write failed"
OUT0="$("$EXE" cluster offsets --topic "$TOPIC" --partition 0 --remote "127.0.0.1:$BROKER_PORT")"
OUT1="$("$EXE" cluster offsets --topic "$TOPIC" --partition 1 --remote "127.0.0.1:$BROKER_PORT")"
[ "$OUT0" = "2 2" ] || fail "partition 0 moved when partition 1 was written ($OUT0)"
# a single-replica partition is trivially committed the moment it is
# written (P3 semantics: HW = min LEO over the replica set)
[ "$OUT1" = "3 3" ] || fail "partition 1 did not advance on its own write ($OUT1)"
pass "watermarks advance per partition (writing to 1 leaves 0 untouched)"

# ---- 4. the default partition stays 0 ----------------------------------
printf 'legacy\n' > "$WORK/legacy.txt"
"$EXE" produce --topic "$TOPIC" --file "$WORK/legacy.txt" --remote "127.0.0.1:$BROKER_PORT" > /dev/null \
  || fail "an unpartitioned produce failed"
OUT="$("$EXE" consume --topic "$TOPIC" --remote "127.0.0.1:$BROKER_PORT")"
printf '%s\n' "$OUT" | cut -f4- | grep -q "legacy" \
  || { printf '%s\n' "$OUT"; fail "the unpartitioned produce did not land in partition 0"; }
pass "a client that says nothing about partitions lands in partition 0"

echo "E2E-P5-PARTITIONS: all green"
