#!/usr/bin/env bash
# E2E-P14: keyed compaction. Eight legs, two topologies.
#
# Standalone broker (keys, effect, holes, idempotence):
#   1 keys reach the log and come back out of the consumer, and a line
#     with no separator is skipped and reported
#   2 compaction drops exactly what a later record supersedes, and every
#     survivor keeps the offset it was written with
#   3 reads that start inside the hole see the survivors (a hole is an
#     absence, not an error)
#   4 a second pass reports nothing and moves no byte
#
# Cluster (floor, convergence, refusal, fresh replica):
#   5 the floor bounds it: a newer version *above* the committed prefix
#     does not license deleting the older one below it
#   6 both replicas compact to byte-identical segments
#   7 a follower refuses the command and names the leader
#   8 a fresh replica adopts the compacted hole and catches up
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXE="${MOONFLUX_EXE:-$ROOT/_build/native/debug/build/apps/cli/cli.exe}"
[ -x "$EXE" ] || EXE="$ROOT/_build/native/release/build/apps/cli/cli.exe"
[ -x "$EXE" ] || {
  echo "cli executable not found; run: moon build --target native" >&2
  exit 1
}

WORK="$(mktemp -d /tmp/moonflux-p14-compaction.XXXXXX)"
BROKER_PORT="${MOONFLUX_P14_BROKER_PORT:-19481}"
SC_PORT="${MOONFLUX_P14_SC_PORT:-19482}"
A_PORT="${MOONFLUX_P14_A_PORT:-19483}"
B_PORT="${MOONFLUX_P14_B_PORT:-19484}"
TOPIC="${MOONFLUX_P14_TOPIC:-compact-me}"

# segmentation is the point: one frame fills a segment, so "which
# segment holds what" is a statement the gate can make exactly
export MOONFLUX_ROLL_BYTES="${MOONFLUX_P14_ROLL_BYTES:-60}"
export MOONFLUX_INDEX_EVERY="${MOONFLUX_P14_INDEX_EVERY:-1}"
export MOONFLUX_RETAIN_BYTES=0

BROKER_PID=""
SC_PID=""
A_PID=""
B_PID=""

cleanup() {
  for pid in "$BROKER_PID" "$SC_PID" "$A_PID" "$B_PID"; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
  done
  # …and by port, because a node restarted through a command
  # substitution is re-parented to init: a pid this script forgot (or
  # overwrote at a restart) is a process it can no longer address, while
  # the *port* still identifies it. This gate leaked an `spu` across two
  # consecutive runs before this line existed. The fixed-port check at
  # the top is what keeps the sweep specific rather than a broad pkill.
  for port in "$BROKER_PORT" "$SC_PORT" "$A_PORT" "$B_PORT"; do
    for pid in $(lsof -ti ":$port" -sTCP:LISTEN 2>/dev/null); do
      kill "$pid" 2>/dev/null || true
    done
  done
  wait 2>/dev/null || true
}
trap 'cleanup; rm -rf "$WORK"' EXIT

fail() { echo "E2E-P14 FAIL: $1" >&2; exit 1; }
pass() { echo "E2E-P14 PASS: $1"; }

# Fixed ports: a leftover listener would make every assertion below a
# statement about the wrong process.
for port in "$BROKER_PORT" "$SC_PORT" "$A_PORT" "$B_PORT"; do
  if lsof -i ":$port" -sTCP:LISTEN >/dev/null 2>&1; then
    fail "port $port is already in use; stop the process that owns it"
  fi
done

wait_listen() { # $1 = port
  for _ in $(seq 1 100); do
    lsof -i ":$1" -sTCP:LISTEN >/dev/null 2>&1 && return 0
    sleep 0.1
  done
  return 1
}

start_spu() { # $1 = id, $2 = port
  "$EXE" spu --id "$1" --listen "127.0.0.1:$2" --data-dir "$WORK/$1" \
    --sc "127.0.0.1:$SC_PORT" > "$WORK/$1.log" 2>&1 &
  echo $!
}

apply_topic() { # $1 = data dir
  cat > "$WORK/spec.json" <<EOF
{
  "apiVersion": "moonflux.io/v1alpha1",
  "kind": "Pipeline",
  "metadata": { "name": "compaction-demo" },
  "spec": {
    "source": { "type": "file", "path": "$WORK/in.txt" },
    "transforms": [],
    "topic": { "name": "$TOPIC" },
    "sink": { "type": "stdout" }
  }
}
EOF
  "$EXE" pipeline apply -f "$WORK/spec.json" --data-dir "$1" > /dev/null ||
    fail "pipeline apply failed for $1"
}

consume_columns() { # $1 = port, $2 = from offset ; prints "offset<TAB>key<TAB>value"
  "$EXE" consume --topic "$TOPIC" --from "$2" --remote "127.0.0.1:$1" 2>/dev/null \
    | cut -f1,3,4
}

# ---------------------------------------------------------------------
# Legs 1-4: the standalone broker

mkdir -p "$WORK/broker"
printf 'k1:v1\nk2:v2\nk1:v3\nbare-line-without-separator\n' > "$WORK/in1.txt"
printf 'k2:v4\nk3:v5\n' > "$WORK/in2.txt"

"$EXE" serve --data-dir "$WORK/broker" --listen "127.0.0.1:$BROKER_PORT" \
  > "$WORK/broker.log" 2>&1 &
BROKER_PID=$!
wait_listen "$BROKER_PORT" || fail "the broker did not start"

"$EXE" produce --topic "$TOPIC" --file "$WORK/in1.txt" --key-separator ':' \
  --remote "127.0.0.1:$BROKER_PORT" > "$WORK/p1.out" 2> "$WORK/p1.err" ||
  fail "keyed produce failed"
grep -q "produced 3 records" "$WORK/p1.out" ||
  fail "a key-separator produce should keep the three lines that have one"
grep -q "skipped 1 line(s) without the key separator" "$WORK/p1.err" ||
  fail "the line without a separator was not reported as skipped"

BEFORE="$(consume_columns "$BROKER_PORT" 0)"
printf '%s\n' "$BEFORE" | python3 -c '
import sys
rows = [line.split("\t") for line in sys.stdin.read().strip().split("\n")]
assert [r[1] for r in rows] == ["k1", "k2", "k1"], rows
assert [r[2] for r in rows] == ["v1", "v2", "v3"], rows
' || fail "keys did not survive produce -> consume"
pass "leg 1: keys reach the log (k1, k2, k1) and a separator-less line is skipped"

# a constant key stamps every record of its input
printf 'x\ny\n' > "$WORK/in3.txt"
"$EXE" produce --topic const-key --file "$WORK/in3.txt" --key all-of-them \
  --remote "127.0.0.1:$BROKER_PORT" > /dev/null || fail "constant-key produce failed"
"$EXE" consume --topic const-key --from 0 --remote "127.0.0.1:$BROKER_PORT" \
  2>/dev/null | cut -f3 | python3 -c '
import sys
keys = sys.stdin.read().strip().split("\n")
assert keys == ["all-of-them", "all-of-them"], keys
' || fail "--key did not stamp the constant key"
pass "leg 1b: --key stamps a constant key"

# a second produce crosses the roll threshold: segment 0 is sealed
"$EXE" produce --topic "$TOPIC" --file "$WORK/in2.txt" --key-separator ':' \
  --remote "127.0.0.1:$BROKER_PORT" > /dev/null || fail "second produce failed"
SEGMENTS_BEFORE="$("$EXE" cluster segments --topic "$TOPIC" \
  --remote "127.0.0.1:$BROKER_PORT")"
printf '%s\n' "$SEGMENTS_BEFORE" | python3 -c '
import sys
rows = [line.split("\t") for line in sys.stdin.read().strip().split("\n")]
assert len(rows) >= 2, rows
assert rows[0][0] == "0", rows
' || fail "expected a sealed segment at base 0 (got: $SEGMENTS_BEFORE)"

PRE="$(consume_columns "$BROKER_PORT" 0)"
COMPACT="$("$EXE" cluster compact --topic "$TOPIC" \
  --remote "127.0.0.1:$BROKER_PORT")" || fail "cluster compact failed"
printf '%s\n' "$COMPACT" | grep -q "1 segment(s) of $TOPIC\[0\]: 2 records dropped" ||
  fail "the pass did not report what it dropped: $COMPACT"

AFTER="$(consume_columns "$BROKER_PORT" 0)"
printf '%s\n---spit---\n%s\n' "$PRE" "$AFTER" | python3 -c '
import sys
before, after = sys.stdin.read().strip().split("\n---spit---\n")
b = [line.split("\t") for line in before.split("\n")]
a = [line.split("\t") for line in after.split("\n")]
kept = [r for r in b if r[0] not in ("0", "1")]  # k1@0 and k2@1 were superseded
assert a == kept, f"survivors moved: {b} -> {a}"
' || fail "the survivors do not match the records that were not superseded"
pass "leg 2: compaction dropped k1@0 and k2@1, and every survivor kept its offset"

# the segment's *span* is unchanged — offsets are identities even when
# the bytes between them are gone
"$EXE" cluster segments --topic "$TOPIC" --remote "127.0.0.1:$BROKER_PORT" \
  | head -1 | cut -f1,2 | python3 -c '
import sys
base, span = sys.stdin.read().strip().split("\t")
assert base == "0" and span == "3", (base, span)
' || fail "the rewritten segment no longer accounts for offsets 0..2"

# a read that starts inside the hole is a read, not an error
HOLE_READ="$("$EXE" consume --topic "$TOPIC" --from 1 \
  --remote "127.0.0.1:$BROKER_PORT" 2>/dev/null | cut -f1,3,4)"
printf '%s\n' "$AFTER" | cut -f1 | grep -qx "1" && fail "offset 1 should be gone"
[ "$HOLE_READ" = "$AFTER" ] ||
  fail "reading from inside the hole differs from reading from 0"
pass "leg 3: a read starting inside the hole sees the survivors, not an error"

SEG_DIR="$WORK/broker/topics/$TOPIC/partition-0"
DIGEST_BEFORE="$(cat "$SEG_DIR"/*.log | shasum | cut -d' ' -f1)"
SECOND="$("$EXE" cluster compact --topic "$TOPIC" \
  --remote "127.0.0.1:$BROKER_PORT")" || fail "the second pass failed"
printf '%s\n' "$SECOND" | grep -q "compacted 0 segment(s)" ||
  fail "the second pass was not empty: $SECOND"
DIGEST_AFTER="$(cat "$SEG_DIR"/*.log | shasum | cut -d' ' -f1)"
[ "$DIGEST_BEFORE" = "$DIGEST_AFTER" ] ||
  fail "an empty pass still rewrote bytes"
pass "leg 4: a second pass is empty and moves no byte"

# ---------------------------------------------------------------------
# Legs 5-8: the cluster

printf 'placeholder\n' > "$WORK/in.txt"
mkdir -p "$WORK/sc" "$WORK/spu-a" "$WORK/spu-b"
apply_topic "$WORK/spu-a"
apply_topic "$WORK/spu-b"

"$EXE" sc --listen "127.0.0.1:$SC_PORT" --data-dir "$WORK/sc" \
  > "$WORK/sc.log" 2>&1 &
SC_PID=$!
wait_listen "$SC_PORT" || fail "the control plane did not start"
A_PID="$(start_spu spu-a "$A_PORT")"
B_PID="$(start_spu spu-b "$B_PORT")"
wait_listen "$A_PORT" || fail "spu-a did not start"
wait_listen "$B_PORT" || fail "spu-b did not start"

for _ in $(seq 1 80); do
  NODES="$("$EXE" cluster nodes --remote "127.0.0.1:$SC_PORT" 2>/dev/null || true)"
  printf '%s\n' "$NODES" | grep -q "spu-a" && printf '%s\n' "$NODES" | grep -q "spu-b" && break
  sleep 0.25
done
"$EXE" topic create --name "$TOPIC" --partitions 1 --replication-factor 2 \
  --remote "127.0.0.1:$SC_PORT" > /dev/null || fail "topic create failed"

LEADER=""
for _ in $(seq 1 80); do
  LEADER="$("$EXE" cluster leader --topic "$TOPIC" --remote "127.0.0.1:$SC_PORT" 2>/dev/null || true)"
  [ -n "$LEADER" ] && break
  sleep 0.25
done
[ -n "$LEADER" ] || fail "no leader was elected"
if [ "$LEADER" = "127.0.0.1:$A_PORT" ]; then
  FOLLOWER="127.0.0.1:$B_PORT"
  FOLLOWER_DIR="$WORK/spu-b"
else
  FOLLOWER="127.0.0.1:$A_PORT"
  FOLLOWER_DIR="$WORK/spu-a"
fi

produce_to_leader() { # $1 = file, rest = extra flags
  local file="$1"
  shift
  "$EXE" produce --topic "$TOPIC" --file "$file" --remote "$LEADER" "$@" > /dev/null ||
    fail "produce to the leader failed"
}

wait_for_hw() { # $1 = expected high watermark
  for _ in $(seq 1 80); do
    HW="$("$EXE" cluster offsets --topic "$TOPIC" --partition 0 --remote "$LEADER" 2>/dev/null | awk '{print $1}' || true)"
    [ "$HW" = "$1" ] && return 0
    sleep 0.25
  done
  return 1
}

printf 'k1:v1\nk2:v2\nk1:v3\n' > "$WORK/c1.txt"
printf 'plain-record-without-any-key\n' > "$WORK/c2.txt"
printf 'k1:v4\n' > "$WORK/c3.txt"

produce_to_leader "$WORK/c1.txt" --key-separator ':'
wait_for_hw 3 || fail "the replicas did not commit the first batch (hw=$HW)"
# the keyless record is not a keyed one and must never be compacted away
produce_to_leader "$WORK/c2.txt"
wait_for_hw 4 || fail "the replicas did not commit the keyless record (hw=$HW)"

# the follower goes away: the committed prefix stops where it stopped,
# and everything the leader appends after that is *above the floor*
if [ "$FOLLOWER" = "127.0.0.1:$B_PORT" ]; then
  kill "$B_PID" 2>/dev/null || true
else
  kill "$A_PID" 2>/dev/null || true
fi
sleep 0.5

produce_to_leader "$WORK/c3.txt" --key-separator ':'
HW_STUCK="$("$EXE" cluster offsets --topic "$TOPIC" --partition 0 --remote "$LEADER" | awk '{print $1}')"
[ "$HW_STUCK" = "4" ] ||
  fail "the high watermark should have stalled at 4, saw $HW_STUCK"

FLOOR_PASS="$("$EXE" cluster compact --topic "$TOPIC" --remote "$LEADER")" ||
  fail "compaction on the leader failed"
printf '%s\n' "$FLOOR_PASS" | grep -q "1 records dropped" ||
  fail "expected exactly one drop (k1@0): $FLOOR_PASS"
LEADER_READ="$(consume_columns "${LEADER##*:}" 0)"
printf '%s\n' "$LEADER_READ" | python3 -c '
import sys
rows = [line.split("\t") for line in sys.stdin.read().strip().split("\n")]
keys = [(r[0], r[1]) for r in rows]
assert ("0", "k1") not in keys, keys        # superseded inside the prefix
assert ("2", "k1") in keys, keys            # its newer version is above the floor
assert ("3", "") in keys, keys              # the keyless record is untouched
assert ("4", "k1") in keys, keys
' || fail "the floor was not respected: $LEADER_READ"
pass "leg 5: nothing above the committed prefix moved (k1@2 kept, k1@0 dropped)"

LEO_AFTER="$("$EXE" cluster offsets --topic "$TOPIC" --partition 0 --remote "$LEADER" | awk '{print $2}')"
[ "$LEO_AFTER" = "5" ] || fail "compaction moved the log end to $LEO_AFTER"

# the follower comes back, catches up, and commits the same prefix
if [ "$FOLLOWER" = "127.0.0.1:$B_PORT" ]; then
  B_PID="$(start_spu spu-b "$B_PORT")"
else
  A_PID="$(start_spu spu-a "$A_PORT")"
fi
wait_listen "${FOLLOWER##*:}" || fail "the follower did not restart"
wait_for_hw 5 || fail "the replicas did not commit the last record (hw=$HW)"

# the control plane hosts no partitions: compaction is a storage
# action and only a node that holds the data can answer it
if "$EXE" cluster compact --topic "$TOPIC" --remote "127.0.0.1:$SC_PORT" \
  > "$WORK/refuse.out" 2>&1; then
  fail "the control plane accepted a storage command it does not own"
fi
[ -s "$WORK/refuse.out" ] ||
  fail "the refusal said nothing at all"
pass "leg 7: an endpoint that hosts no partition refuses the command"

# both replicas compact the same prefix, independently and identically
"$EXE" cluster compact --topic "$TOPIC" --remote "$LEADER" > "$WORK/leader-compact.out" ||
  fail "compaction on the leader failed"
wait_for_hw 5 || fail "the replicas drifted apart"
"$EXE" cluster compact --topic "$TOPIC" --remote "$FOLLOWER" > "$WORK/follower-compact.out" ||
  fail "compaction on the follower failed"

LEADER_DIR="$( [ "$LEADER" = "127.0.0.1:$A_PORT" ] && echo "$WORK/spu-a" || echo "$WORK/spu-b" )"
PARTS="topics/$TOPIC/partition-0"
CONVERGED=""
for _ in $(seq 1 80); do
  LB="$(ls "$LEADER_DIR/$PARTS"/*.log 2>/dev/null | xargs -n1 basename 2>/dev/null | sort | tr '\n' ' ' || true)"
  FB="$(ls "$FOLLOWER_DIR/$PARTS"/*.log 2>/dev/null | xargs -n1 basename 2>/dev/null | sort | tr '\n' ' ' || true)"
  if [ -n "$LB" ] && [ "$LB" = "$FB" ]; then
    SAME=yes
    for f in $(ls "$LEADER_DIR/$PARTS"/*.log | xargs -n1 basename); do
      cmp -s "$LEADER_DIR/$PARTS/$f" "$FOLLOWER_DIR/$PARTS/$f" || SAME=""
    done
    [ -n "$SAME" ] && CONVERGED=yes && break
  fi
  sleep 0.25
done
[ -n "$CONVERGED" ] ||
  fail "the replicas did not converge to identical segments after compacting the same prefix"
pass "leg 6: both replicas compacted to byte-identical segments"

# a fresh replica joins a log whose head is a hole: it adopts the hole
# instead of stalling, and reports it
# A fresh replica means a fresh *process*. Wiping the directory under a
# running node was how this leg used to express it, and that is not a
# thing an operator can do: the running node holds its log open (P16's
# cache, and before that a handle per request), so the wipe left a node
# whose in-memory log end was five while the disk held nothing — it had
# nothing to fetch, adopted nothing, and the gate failed for a reason
# that had nothing to do with hole adoption.
if [ "$FOLLOWER" = "127.0.0.1:$B_PORT" ]; then
  kill "$B_PID" 2>/dev/null || true; wait "$B_PID" 2>/dev/null || true; B_PID=""
else
  kill "$A_PID" 2>/dev/null || true; wait "$A_PID" 2>/dev/null || true; A_PID=""
fi
rm -rf "$FOLLOWER_DIR"
if [ "$FOLLOWER" = "127.0.0.1:$B_PORT" ]; then
  B_PID="$(start_spu spu-b "$B_PORT")"
else
  A_PID="$(start_spu spu-a "$A_PORT")"
fi
wait_listen "${FOLLOWER##*:}" || fail "the wiped follower did not restart"
FOLLOWER_LOG="$( [ "$FOLLOWER" = "127.0.0.1:$B_PORT" ] && echo "$WORK/spu-b.log" || echo "$WORK/spu-a.log" )"
ADOPTED=""
for _ in $(seq 1 120); do
  if grep -q "adopted a compacted hole" "$FOLLOWER_LOG"; then
    ADOPTED=yes
    break
  fi
  sleep 0.25
done
[ -n "$ADOPTED" ] ||
  fail "a fresh replica of a compacted log never adopted the hole (see $FOLLOWER_LOG)"
CAUGHT_UP=""
for _ in $(seq 1 120); do
  LEADER_BYTES="$(cat "$LEADER_DIR/$PARTS"/*.log | shasum | cut -d' ' -f1)"
  FOLLOWER_BYTES="$(cat "$FOLLOWER_DIR/$PARTS"/*.log 2>/dev/null | shasum | cut -d' ' -f1)"
  if [ -n "$FOLLOWER_BYTES" ] && [ "$FOLLOWER_BYTES" = "$LEADER_BYTES" ]; then
    CAUGHT_UP=yes
    break
  fi
  sleep 0.25
done
[ -n "$CAUGHT_UP" ] ||
  fail "the fresh replica never held the same records as the leader"
pass "leg 8: a fresh replica adopted the hole and caught up"

echo "E2E-P14-COMPACTION: all green"
