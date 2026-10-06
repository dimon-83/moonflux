#!/bin/bash
# E2E-P28: background compaction joins the maintenance cadences.
#
#   1. default off: keyed supersessions survive every housekeeping tick
#      when no operator asked for compaction — rewriting is never a default
#   2. MOONFLUX_COMPACT_MS turns the pass on: sealed segments shrink to
#      the last version per key, survivors keep their offsets, and a
#      produce that lands between passes survives the next one
#   3. the consumer-group floor holds: versions below the member's
#      commit compact to the last one below it, and superseded records
#      at or above the floor all survive
#   4. the manual `cluster compact` keeps its semantics (threshold 0)
#   5. the same pass runs on a cluster node's leader path (spu), on its
#      own per-partition cadence, not on the 50 ms tick
#
# Every disk assertion goes through tools/decode_log_frames.py: the
# segment file is the protocol stream, so "what is on disk" needs no
# connection and no trust in the server's answers.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
EXE="${MOONFLUX_EXE:-$ROOT/_build/native/debug/build/apps/cli/cli.exe}"
[ -x "$EXE" ] || EXE="$ROOT/_build/native/release/build/apps/cli/cli.exe"

WORK="${MOONFLUX_P28_WORK:-/tmp/moonflux-p28-maintenance}"
SERVE_PORT="${MOONFLUX_P28_SERVE_PORT:-19781}"
SC_PORT="${MOONFLUX_P28_SC_PORT:-19783}"
SPU_PORT="${MOONFLUX_P28_SPU_PORT:-19784}"
SERVE="127.0.0.1:$SERVE_PORT"
SC="127.0.0.1:$SC_PORT"
TOPIC="maint-me"

fail() { echo "E2E-P28 FAIL: $*" >&2; exit 1; }
pass() { echo "E2E-P28 PASS: $*"; }

PIDS=()
cleanup() {
  for pid in "${PIDS[@]:-}"; do kill "$pid" 2>/dev/null || true; done
  pkill -f "moonflux-p28-maintenance" 2>/dev/null || true
}
trap 'cleanup' EXIT

wait_listen() { # $1 = port
  for _ in $(seq 1 60); do
    lsof -i ":$1" -sTCP:LISTEN > /dev/null 2>&1 && return 0
    sleep 0.1
  done
  return 1
}

# the P12/P13 lesson (rework ledger #13): a service announces itself in
# its log some time after the port opens — wait for the line, not the port
wait_log() { # $1 = log file, $2 = pattern, $3 = deadline seconds
  local deadline=$((SECONDS + ${3:-10}))
  while [ "$SECONDS" -lt "$deadline" ]; do
    grep -q "$2" "$1" && return 0
    sleep 0.2
  done
  tail -5 "$1" >&2
  return 1
}

start_serve() { # $1 = log suffix; knobs travel via the environment
  "$EXE" serve --data-dir "$WORK/serve" --listen "$SERVE" \
    > "$WORK/serve-$1.log" 2>&1 &
  SERVE_PID=$!
  PIDS+=("$SERVE_PID")
}

produce_batch() { # $1 = file
  "$EXE" produce --topic "$TOPIC" --file "$1" --key-separator : \
    --remote "$SERVE" > /dev/null || fail "produce failed ($1)"
}

# Decodes everything on disk into $WORK/disk.txt ("offset key value"
# lines) — the one source of truth for every survivor assertion below.
disk_records() {
  : > "$WORK/all-segments.bin"
  for f in $(ls "$WORK/serve/topics/$TOPIC/partition-0"/*.log 2>/dev/null | sort); do
    cat "$f" >> "$WORK/all-segments.bin"
  done
  [ -s "$WORK/all-segments.bin" ] \
    || fail "nothing on disk under $WORK/serve/topics/$TOPIC"
  python3 "$ROOT/tools/decode_log_frames.py" "$WORK/all-segments.bin" \
    > "$WORK/disk.txt" || fail "the on-disk frames do not decode"
}

# Asserts the exact surviving offsets of one key on the last decode.
# The decoder prints four columns: TRUE offset (frame base + position
# within the frame), frame base, key, value — holes are gaps in column 1.
assert_key_offsets() { # $1 = key, $2 = comma-separated expected offsets
  python3 - "$WORK/disk.txt" "$1" "$2" <<'PYEOF' || fail "survivor set wrong for key $1 (expected $2)"
import sys
disk, key, expected = sys.argv[1], sys.argv[2], sys.argv[3]
got = sorted(int(parts[0]) for parts in
             (line.split("\t") for line in open(disk).read().splitlines())
             if len(parts) >= 4 and parts[2] == key)
want = sorted(int(x) for x in expected.split(","))
if got != want:
    sys.exit(f"key {key}: offsets on disk {got}, expected {want}")
PYEOF
}

# Asserts each key has exactly one survivor and it carries $2's value.
assert_single_survivor() { # $1 = disk file, $2.. = key=value pairs
  python3 - "$@" <<'PYEOF' || fail "the survivors are not the latest version per key"
import sys
rows = [line.split("\t") for line in open(sys.argv[1]).read().splitlines() if line.strip()]
for pair in sys.argv[2:]:
    key, want_value = pair.split("=", 1)
    survivors = [(int(parts[0]), parts[3]) for parts in rows
                 if len(parts) >= 4 and parts[2] == key]
    assert len(survivors) == 1 and survivors[0][1] == want_value, \
        f"key {key}: expected exactly {want_value!r}, got {survivors}"
print("  latest version per key, at its original offset")
PYEOF
}

# Waits until a partition directory converges to exactly the latest
# version per key. The pass is periodic, and produces interleave with
# it — a sample taken the instant the first report appears can catch a
# mid-stream state, so the assertion polls until the story is sealed
# (after convergence the passes are idempotent no-ops and it stays).
wait_single_survivor() { # $1 = partition dir, $2.. = key=value pairs
  local dir="$1"
  shift
  for _ in $(seq 1 50); do
    : > "$WORK/chk.bin"
    for f in $(ls "$dir"/*.log 2>/dev/null | sort); do cat "$f" >> "$WORK/chk.bin"; done
    if [ -s "$WORK/chk.bin" ]; then
      python3 "$ROOT/tools/decode_log_frames.py" "$WORK/chk.bin" \
        > "$WORK/chk.txt" 2>/dev/null || true
      if python3 - "$WORK/chk.txt" "$@" 2>/dev/null <<'PYEOF'
import sys
rows = [line.split("\t") for line in open(sys.argv[1]).read().splitlines() if line.strip()]
for pair in sys.argv[2:]:
    key, want_value = pair.split("=", 1)
    survivors = [(int(parts[0]), parts[3]) for parts in rows
                 if len(parts) >= 4 and parts[2] == key]
    if not (len(survivors) == 1 and survivors[0][1] == want_value):
        sys.exit(1)
print("  latest version per key, at its original offset")
PYEOF
      then
        return 0
      fi
    fi
    sleep 0.2
  done
  fail "the survivors never converged to the latest version per key ($*)"
}

rm -rf "$WORK"
mkdir -p "$WORK/serve"

# ten supersessions across two keys, five versions each, delivered as
# five separate produces: a produce is one frame and rolling happens
# between appends, so five appends with MOONFLUX_ROLL_BYTES=50 are
# what create the sealed segments a compaction pass can rewrite
for i in 1 2 3 4 5; do
  printf 'k1:v%s\nk2:w%s\n' "$i" "$i" > "$WORK/part-$i.txt"
done

produce_supersessions() {
  for i in 1 2 3 4 5; do
    produce_batch "$WORK/part-$i.txt"
  done
}

# ---- 1. default off: no operator, no rewrite ---------------------------
MOONFLUX_ROLL_BYTES=50 start_serve off
wait_listen "$SERVE_PORT" || { cat "$WORK/serve-off.log"; fail "serve did not start"; }
produce_supersessions
sleep 4   # four housekeeping ticks (1 s each) — an eager pass would show
if grep -q "compacted $TOPIC\[" "$WORK/serve-off.log"; then
  fail "background compaction ran without MOONFLUX_COMPACT_MS (rewriting is not a default)"
fi
disk_records
N_OFF="$(grep -c . "$WORK/disk.txt")"
[ "$N_OFF" = "10" ] || fail "expected all 10 versions on disk with the pass off, found $N_OFF"
pass "default is off: all 10 versions still on disk after 4 housekeeping ticks, no compaction line"

# ---- 2. the knob turns the pass on --------------------------------------
kill "$SERVE_PID" 2>/dev/null; wait "$SERVE_PID" 2>/dev/null
MOONFLUX_ROLL_BYTES=50 MOONFLUX_COMPACT_MS=300 start_serve on
wait_listen "$SERVE_PORT" || { cat "$WORK/serve-on.log"; fail "serve did not restart"; }
wait_log "$WORK/serve-on.log" "compacted $TOPIC\[" 10 \
  || fail "the first background pass never reported a rewrite"
wait_single_survivor "$WORK/serve/topics/$TOPIC/partition-0" "k1=v5" "k2=w5"
pass "MOONFLUX_COMPACT_MS=300: disk shrank to the latest version per key, offsets unchanged"

# records produced between passes survive the next one (the active
# segment is never rewritten, and idempotence covers the rest)
printf 'k1:v6\nk2:w6\nfill:z1\nfill:z2\n' > "$WORK/more.txt"
produce_batch "$WORK/more.txt"
BEFORE="$(grep -c "compacted $TOPIC\[" "$WORK/serve-on.log")"
# wait for the COUNT to move: the pattern is already present, so a
# presence check returns instantly and races the 300 ms cadence
AFTER="$BEFORE"
for _ in $(seq 1 50); do
  AFTER="$(grep -c "compacted $TOPIC\[" "$WORK/serve-on.log")"
  [ "$AFTER" -gt "$BEFORE" ] && break
  sleep 0.2
done
[ "$AFTER" -gt "$BEFORE" ] || fail "no pass ran after the new records (stuck at $BEFORE lines)"
wait_single_survivor "$WORK/serve/topics/$TOPIC/partition-0" "k1=v6" "k2=w6"
disk_records
N_FILL="$(awk -F'\t' '$3 == "fill"' "$WORK/disk.txt" | wc -l | tr -d ' ')"
[ "$N_FILL" = "2" ] || fail "the filler records were lost ($N_FILL on disk)"
pass "records produced between passes survive; the chain stays consistent through maintenance"

# ---- 3. the consumer-group floor holds ----------------------------------
# the member commits offset 11 BEFORE the supersessions exist, so no
# pass can ever see a floor above 11: k1's version at 10 is the last one
# strictly below the floor and must survive, while v7@14 and v8@15 are
# at-or-above it — superseded, yet untouchable. With the floor in force
# nothing below it is droppable, so the passes here are (correct) no-ops
# and the assertion is the disk itself after several pass intervals
"$EXE" consume --topic "$TOPIC" --group slowfns --member m1 --follow \
  --commit-ms 60000 --remote "$SERVE" > "$WORK/slow.out" 2>> "$WORK/slow.err" &
SLOW_PID=$!
PIDS+=("$SLOW_PID")
EPOCH=""
for _ in $(seq 1 60); do
  EPOCH="$("$EXE" group describe --name slowfns --remote "$SERVE" 2>/dev/null | head -1 | sed 's/.*epoch=//' || true)"
  [ -n "$EPOCH" ] && break
  sleep 0.25
done
[ -n "$EPOCH" ] || { cat "$WORK/slow.err"; fail "the group never joined"; }
"$EXE" group commit --group slowfns --member m1 --topic "$TOPIC" \
  --partition 0 --offset 11 --epoch "$EPOCH" --remote "$SERVE" > /dev/null \
  || fail "the group could not commit offset 11"
printf 'k1:v7\nk1:v8\n' > "$WORK/above.txt"
produce_batch "$WORK/above.txt"
sleep 2   # five pass intervals: any of them would drop v7@14 if the floor did not hold
disk_records
assert_key_offsets "k1" "10,14,15"
assert_key_offsets "k2" "11"
assert_key_offsets "fill" "12,13"
pass "the group floor held: k1 kept its last version below offset 11 AND the superseded ones at 14,15"
kill "$SLOW_PID" 2>/dev/null; wait "$SLOW_PID" 2>/dev/null

# ---- 4. the manual command keeps its semantics ---------------------------
kill "$SERVE_PID" 2>/dev/null; wait "$SERVE_PID" 2>/dev/null
rm -rf "$WORK/serve"
mkdir -p "$WORK/serve"
MOONFLUX_ROLL_BYTES=50 start_serve manual
wait_listen "$SERVE_PORT" || { cat "$WORK/serve-manual.log"; fail "serve did not start (manual leg)"; }
produce_supersessions
OUT="$("$EXE" cluster compact --topic "$TOPIC" --remote "$SERVE")" \
  || fail "cluster compact failed: $OUT"
printf '%s\n' "$OUT" | grep -q "records dropped" \
  || fail "the manual pass did not report what it dropped: $OUT"
disk_records
assert_single_survivor "$WORK/disk.txt" "k1=v5" "k2=w5" \
  || fail "the manual command left the wrong survivors"
pass "cluster compact answers immediately without any knob (threshold 0, as before)"

# ---- 5. the cluster node's leader path runs the same pass ---------------
kill "$SERVE_PID" 2>/dev/null; wait "$SERVE_PID" 2>/dev/null
mkdir -p "$WORK/sc" "$WORK/spu"
"$EXE" sc --listen "$SC" --data-dir "$WORK/sc" > "$WORK/sc.log" 2>&1 &
SC_PID=$!
PIDS+=("$SC_PID")
MOONFLUX_ROLL_BYTES=50 MOONFLUX_COMPACT_MS=300 \
  "$EXE" spu --id A --listen "127.0.0.1:$SPU_PORT" --sc "$SC" \
  --data-dir "$WORK/spu" > "$WORK/spu.log" 2>&1 &
SPU_PID=$!
PIDS+=("$SPU_PID")
wait_listen "$SC_PORT" || { cat "$WORK/sc.log"; fail "sc did not start"; }
wait_listen "$SPU_PORT" || { cat "$WORK/spu.log"; fail "spu did not start"; }
"$EXE" topic create --name spu-topic --partitions 1 --replication-factor 1 \
  --remote "$SC" > /dev/null || fail "topic create failed"
# the control plane declares; the node learns its placement from
# heartbeats. Produces go to the LEADER (the control plane is not a
# data path), whose address the SC hands out once placement is done
LEADER=""
for _ in $(seq 1 80); do
  LEADER="$("$EXE" cluster leader --topic spu-topic --remote "$SC" 2>/dev/null || true)"
  [ -n "$LEADER" ] && break
  sleep 0.25
done
[ -n "$LEADER" ] || { cat "$WORK/sc.log"; cat "$WORK/spu.log"; fail "the cluster never assigned a leader for spu-topic"; }
for i in 1 2 3 4 5; do
  "$EXE" produce --topic spu-topic --file "$WORK/part-$i.txt" --key-separator : \
    --remote "$LEADER" > /dev/null || fail "produce part-$i failed"
done
wait_log "$WORK/spu.log" "compacted spu-topic\[0\]" 15 \
  || fail "the node's leader path never ran the background pass"
wait_single_survivor "$WORK/spu/topics/spu-topic/partition-0" "k1=v5" "k2=w5"
pass "a cluster node's leader compacts on its own cadence (not the 50 ms tick), same floor rules"

echo "E2E-P28 PASS: 5 legs green"
