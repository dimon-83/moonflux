#!/bin/bash
# P8 gate: a partition's log is a sequence of segments, indexed, and it
# can be told to let go of what nobody needs.
#
#   1. rolling: a small threshold produces several segments, and the
#      operator can see them (`cluster segments`)
#   2. reads are segment-agnostic: the same records read back exactly
#      as they do from a log that never rolled
#   3. the index is an accelerator: deleting every .idx and reopening
#      gives byte-identical reads (the rebuild path)
#   4. retention: whole segments below the committed prefix are
#      dropped, reported, and reads below the new start are *refused*
#   5. a torn tail: truncating the last segment loses only the tail,
#      and the sealed segments' bytes are untouched
#   6. replication across segments: the follower's segment *files* are
#      byte-identical to the leader's, per segment
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# The debug build is what `moon build --target native` (and `moon test`)
# produce, so it is the artifact every gate here means to test. A release
# binary is only a fallback: preferring it once meant a gate silently
# tested a build from an earlier session.
EXE="${MOONFLUX_EXE:-$ROOT/_build/native/debug/build/apps/cli/cli.exe}"
[ -x "$EXE" ] || EXE="$ROOT/_build/native/release/build/apps/cli/cli.exe"
[ -x "$EXE" ] || { echo "cli executable not found; run: moon build --target native" >&2; exit 1; }

WORK="$(mktemp -d /tmp/moonflux-p8-storage.XXXXXX)"
BROKER_PORT="${MOONFLUX_P8_BROKER_PORT:-19461}"
FLAT_PORT="${MOONFLUX_P8_FLAT_PORT:-19462}"
SC_PORT="${MOONFLUX_P8_SC_PORT:-19463}"
A_PORT="${MOONFLUX_P8_A_PORT:-19464}"
B_PORT="${MOONFLUX_P8_B_PORT:-19465}"
TOPIC="events"
# a threshold small enough that a handful of records rolls several
# times, and anchors every few records so the index is exercised
# a frame is ~18 bytes here, so 40 rolls every couple of records
ROLL_BYTES="${MOONFLUX_P8_ROLL_BYTES:-40}"
INDEX_EVERY="${MOONFLUX_P8_INDEX_EVERY:-2}"
RETAIN_BYTES="${MOONFLUX_P8_RETAIN_BYTES:-150}"
# rolling and indexing are on for every broker start (they change
# nothing a reader can see); retention is opt-in per leg, because it is
# the one policy that *removes* data
export MOONFLUX_ROLL_BYTES="$ROLL_BYTES"
export MOONFLUX_INDEX_EVERY="$INDEX_EVERY"
export MOONFLUX_RETAIN_BYTES=0
BROKER_PID=""; FLAT_PID=""; SC_PID=""; A_PID=""; B_PID=""
cleanup() {
  for pid in "$BROKER_PID" "$FLAT_PID" "$SC_PID" "$A_PID" "$B_PID"; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
    [ -n "$pid" ] && wait "$pid" 2>/dev/null || true
  done
}
trap 'cleanup; rm -rf "$WORK"' EXIT

fail() { echo "E2E-P8-STORAGE FAIL: $*" >&2; exit 1; }
pass() { echo "E2E-P8-STORAGE PASS: $*"; }

# a stale process on one of the fixed ports would silently serve its own
# (deleted) data dir and every assertion below would be about the wrong
# broker: refuse to start in that case instead of lying
for port in "$BROKER_PORT" "$FLAT_PORT" "$SC_PORT" "$A_PORT" "$B_PORT"; do
  if lsof -i ":$port" -sTCP:LISTEN > /dev/null 2>&1; then
    echo "E2E-P8-STORAGE FAIL: port $port is already in use (stale process?)" >&2
    exit 1
  fi
done

wait_listen() { # $1 = port
  for _ in $(seq 1 60); do
    lsof -i ":$1" -sTCP:LISTEN > /dev/null 2>&1 && return 0
    sleep 0.1
  done
  return 1
}

start_broker() { # $1 = data dir, $2 = port, $3 = log file, extra env pre-set
  "$EXE" serve --data-dir "$1" --listen "127.0.0.1:$2" > "$3" 2>&1 &
  echo $!
}

apply_topic() { # $1 = data dir, $2 = topic
  "$EXE" pipeline apply -f /dev/stdin --data-dir "$1" <<EOF > /dev/null
{
  "apiVersion": "moonflux.io/v1alpha1",
  "kind": "Pipeline",
  "metadata": { "name": "storage-demo" },
  "spec": {
    "source": { "type": "file", "path": "$WORK/in.txt" },
    "transforms": [],
    "topic": { "name": "$2" },
    "sink": { "type": "stdout" }
  }
}
EOF
}

segments_of() { # $1 = port -> "base records bytes" lines
  "$EXE" cluster segments --topic "$TOPIC" --remote "127.0.0.1:$1"
}

# segment bytes, concatenated in base order: "the log" independent of
# how it happens to be cut
partition_bytes() { # $1 = data dir, $2 = out
  : > "$2"
  local dir="$1/topics/$TOPIC/partition-0"
  for f in $(ls "$dir"/*.log 2>/dev/null | sort); do
    cat "$f" >> "$2"
  done
}

# ---- 1. rolling ---------------------------------------------------------
# rolling happens at batch boundaries (a batch is a frame, and a frame
# is never split), so several produces produce several segments
printf 'r0\nr1\nr2\n' > "$WORK/in.txt"
mkdir -p "$WORK/rolled" "$WORK/flat" "$WORK/sc" "$WORK/spu-a" "$WORK/spu-b"
apply_topic "$WORK/rolled" "$TOPIC"
apply_topic "$WORK/flat" "$TOPIC"

BROKER_PID="$(start_broker "$WORK/rolled" "$BROKER_PORT" "$WORK/rolled.log")"
wait_listen "$BROKER_PORT" || { cat "$WORK/rolled.log"; fail "broker did not start"; }

for _ in 1 2 3; do
  "$EXE" produce --topic "$TOPIC" --file "$WORK/in.txt" --remote "127.0.0.1:$BROKER_PORT" > /dev/null \
    || fail "produce failed"
done
SEGMENTS="$(segments_of "$BROKER_PORT")"
COUNT=$(printf '%s\n' "$SEGMENTS" | grep -c . || true)
[ "$COUNT" -ge 3 ] || { printf '%s\n' "$SEGMENTS"; fail "expected several segments, saw $COUNT"; }
# the segments tile the offset space: bases ascend and records add up
printf '%s\n' "$SEGMENTS" > "$WORK/segments.tsv"
python3 - "$WORK/segments.tsv" <<'PY' || fail "the segments do not tile the log"
import sys
with open(sys.argv[1]) as fh:
    rows = [l.split("\t") for l in fh.read().strip().split("\n") if l]
bases = [int(r[0]) for r in rows]
records = [int(r[1]) for r in rows]
assert bases[0] == 0, f"first segment starts at {bases[0]}"
total = 0
for i, b in enumerate(bases):
    assert b == total, f"segment {i} starts at {b}, expected {total}"
    total += records[i]
assert total == 9, f"segments cover {total} records, expected 9"
PY
pass "rolling produced $COUNT segments and they tile the log"

# ---- 2. reads do not care about segmentation ---------------------------
"$EXE" consume --topic "$TOPIC" --remote "127.0.0.1:$BROKER_PORT" | cut -f4- > "$WORK/rolled.out"
printf 'r0\nr1\nr2\nr0\nr1\nr2\nr0\nr1\nr2\n' > "$WORK/want.out"
diff -u "$WORK/want.out" "$WORK/rolled.out" || { cat "$WORK/rolled.out"; fail "cross-segment read"; }

# the same records into a broker that never rolls: identical output and
# identical bytes on disk (segmentation must be invisible)
FLAT_PID="$(MOONFLUX_ROLL_BYTES=100000000 MOONFLUX_INDEX_EVERY=1000 MOONFLUX_RETAIN_BYTES=0 start_broker "$WORK/flat" "$FLAT_PORT" "$WORK/flat.log")"
wait_listen "$FLAT_PORT" || fail "flat broker did not start"
for _ in 1 2 3; do
  "$EXE" produce --topic "$TOPIC" --file "$WORK/in.txt" --remote "127.0.0.1:$FLAT_PORT" > /dev/null \
    || fail "produce to the flat broker failed"
done
"$EXE" consume --topic "$TOPIC" --remote "127.0.0.1:$FLAT_PORT" | cut -f4- > "$WORK/flat.out"
diff -u "$WORK/want.out" "$WORK/flat.out" || {
  printf 'want=%s flat=%s records; flat broker log:\n' "$(wc -l < "$WORK/want.out" | tr -d ' ')" "$(wc -l < "$WORK/flat.out" | tr -d ' ')"
  tail -5 "$WORK/flat.log"
  fail "the flat broker returned different records"
}
# the two logs are not byte-compared: each broker stamps its own
# timestamps, so the frames legitimately differ. What must not differ
# is what a reader sees — and the byte-level property that matters is
# leader-vs-follower (leg 6), where the bytes are replicated verbatim.
SEG_ROLLED=$(segments_of "$BROKER_PORT" | grep -c . || true)
SEG_FLAT=$(segments_of "$FLAT_PORT" | grep -c . || true)
[ "$SEG_FLAT" -lt "$SEG_ROLLED" ] \
  || fail "the flat broker also segmented ($SEG_FLAT vs $SEG_ROLLED)"
pass "a rolling log reads exactly like a single-segment one ($SEG_ROLLED segments vs $SEG_FLAT)"

# ---- 3. the index is an accelerator ------------------------------------
kill "$BROKER_PID" 2>/dev/null || true; wait "$BROKER_PID" 2>/dev/null || true
# `find` rather than `ls`: with `set -o pipefail`, a glob that matches
# nothing makes `ls` fail, which killed this script *before* the check
# below could say why — a red gate with no message is the worst kind of
# red (P16 hit it: the assertion that would have named the problem never
# ran).
IDX_COUNT=$(find "$WORK/rolled/topics/$TOPIC/partition-0" -name '*.idx' 2>/dev/null | wc -l | tr -d ' ')
[ "$IDX_COUNT" -ge 2 ] || fail "no index files were written (found $IDX_COUNT)"
rm -f "$WORK/rolled/topics/$TOPIC/partition-0"/*.idx
BROKER_PID="$(start_broker "$WORK/rolled" "$BROKER_PORT" "$WORK/rolled.log")"
wait_listen "$BROKER_PORT" || fail "broker did not restart"
"$EXE" consume --topic "$TOPIC" --remote "127.0.0.1:$BROKER_PORT" | cut -f4- > "$WORK/rolled2.out"
diff -u "$WORK/want.out" "$WORK/rolled2.out" \
  || fail "reads changed after the index was removed (fallback must be identical)"
pass "with every .idx deleted, reads are byte-identical (scan fallback)"

# ---- 4. retention drops what nobody needs ------------------------------
# the policy is an operator's decision, so it is set here rather than
# for the whole run: nothing below the committed prefix was needed by
# anyone, and the broker says what it dropped
kill "$BROKER_PID" 2>/dev/null || true; wait "$BROKER_PID" 2>/dev/null || true
BROKER_PID="$(MOONFLUX_RETAIN_BYTES="$RETAIN_BYTES" start_broker "$WORK/rolled" "$BROKER_PORT" "$WORK/rolled.log")"
wait_listen "$BROKER_PORT" || fail "broker did not restart with retention on"
printf 'z0\nz1\nz2\nz3\nz4\nz5\nz6\nz7\nz8\nz9\n' > "$WORK/more.txt"
"$EXE" produce --topic "$TOPIC" --file "$WORK/more.txt" --remote "127.0.0.1:$BROKER_PORT" > /dev/null \
  || fail "produce for retention failed"
DELETED=""
for _ in $(seq 1 40); do
  if grep -q "retained away $TOPIC\[0\]" "$WORK/rolled.log"; then
    DELETED=yes
    break
  fi
  sleep 0.25
done
[ -n "$DELETED" ] || { cat "$WORK/rolled.log"; fail "retention never ran"; }
grep -q "earliest readable offset is now" "$WORK/rolled.log" \
  || fail "the retention log line does not say where reads now start"
FIRST="$(segments_of "$BROKER_PORT" | head -1 | cut -f1)"
[ "$FIRST" -gt 0 ] || fail "the first segment is still at 0: nothing was retained"
# below the new start: a structured refusal, not an empty answer
if "$EXE" consume --topic "$TOPIC" --from 0 --remote "127.0.0.1:$BROKER_PORT" > "$WORK/old.out" 2> "$WORK/old.err"; then
  fail "reading below the retained start should be refused"
fi
[ -s "$WORK/old.out" ] && fail "the refused read still returned records"
grep -qi "range" "$WORK/old.err" || { cat "$WORK/old.err"; fail "the refusal does not explain itself"; }
pass "reading below the retained start is refused with a reason ($(head -c 60 "$WORK/old.err"))"
# at and above it: served, with the records that survived. Retention
# keeps running, and the log line this leg waits for may come from a
# sweep that has only deleted the first segment so far — the startup
# sweep can even run before this leg's produce lands (which is fine:
# deletion is always legal below the committed prefix; surfaced when
# the hub stopped sleeping through its accept block, P17/ticket 75).
# So the wait is for the *settled* window: readable, non-empty, and
# starting where retention means it to start.
SERVED=""
for _ in $(seq 1 16); do
  FIRST="$(segments_of "$BROKER_PORT" | head -1 | cut -f1)"
  if "$EXE" consume --topic "$TOPIC" --from "$FIRST" --remote "127.0.0.1:$BROKER_PORT" \
      | cut -f4- > "$WORK/kept.out" 2>/dev/null; then
    if head -1 "$WORK/kept.out" | grep -q '^z'; then
      SERVED=yes
      break
    fi
  fi
  sleep 0.5
done
[ -n "$SERVED" ] || { head -3 "$WORK/kept.out" 2>/dev/null; fail "the surviving window did not settle on the retained records"; }
[ -s "$WORK/kept.out" ] || fail "the surviving window is empty"
pass "retention dropped segments below the committed prefix (start is now $FIRST) and refuses older reads"

# ---- 5. a torn tail only costs the tail ---------------------------------
# Its own broker and data dir with retention off: this leg is about
# recovery, and a retention pass running underneath it would move the
# very segments being inspected.
kill "$BROKER_PID" 2>/dev/null || true; wait "$BROKER_PID" 2>/dev/null || true
BROKER_PID=""
mkdir -p "$WORK/torn"
apply_topic "$WORK/torn" "$TOPIC"
BROKER_PID="$(start_broker "$WORK/torn" "$BROKER_PORT" "$WORK/torn.log")"
wait_listen "$BROKER_PORT" || fail "torn broker did not start"
for _ in 1 2 3 4; do
  "$EXE" produce --topic "$TOPIC" --file "$WORK/in.txt" --remote "127.0.0.1:$BROKER_PORT" > /dev/null \
    || fail "produce for the torn-tail leg failed"
done
TORN_DIR="$WORK/torn/topics/$TOPIC/partition-0"
SEG_ROWS="$(segments_of "$BROKER_PORT")"
BEFORE_RECORDS=$(printf '%s\n' "$SEG_ROWS" | python3 -c 'import sys; print(sum(int(l.split("\t")[1]) for l in sys.stdin if l.strip()))')
LAST_RECORDS=$(printf '%s\n' "$SEG_ROWS" | tail -1 | cut -f2)
[ "$(printf '%s\n' "$SEG_ROWS" | grep -c .)" -ge 2 ] || { printf '%s\n' "$SEG_ROWS"; fail "the torn-tail leg needs several segments"; }
kill "$BROKER_PID" 2>/dev/null || true; wait "$BROKER_PID" 2>/dev/null || true
BROKER_PID=""

# hash every sealed segment by name: recovery must not touch them
# (the torn one may legitimately disappear, so the comparison is per
# file, over the names that survive)
BEFORE_MAP="$(for f in $(ls "$TORN_DIR"/*.log | sort | sed '$d'); do
  printf '%s %s\n' "$(basename "$f")" "$(shasum "$f" | cut -d' ' -f1)"
done)"
LAST="$(ls "$TORN_DIR"/*.log | sort | tail -1)"
SIZE=$(wc -c < "$LAST" | tr -d ' ')
[ "$SIZE" -gt 4 ] || fail "the last segment is too small to tear"
head -c "$((SIZE - 3))" "$LAST" > "$LAST.torn" && mv "$LAST.torn" "$LAST"
BROKER_PID="$(start_broker "$WORK/torn" "$BROKER_PORT" "$WORK/torn.log")"
wait_listen "$BROKER_PORT" || fail "torn broker did not restart"
RECOVERED=""
for _ in $(seq 1 20); do
  segments_of "$BROKER_PORT" > /dev/null 2>&1 || true
  grep -q "recovery discarded" "$WORK/torn.log" && RECOVERED=yes && break
  sleep 0.25
done
[ -n "$RECOVERED" ] || { tail -6 "$WORK/torn.log"; fail "the torn tail was not reported"; }
CHECKED=0
while read -r name hash; do
  [ -n "$name" ] || continue
  [ -f "$TORN_DIR/$name" ] || continue
  NOW="$(shasum "$TORN_DIR/$name" | cut -d' ' -f1)"
  [ "$NOW" = "$hash" ] || fail "recovery rewrote the sealed segment $name"
  CHECKED=$((CHECKED + 1))
done <<< "$BEFORE_MAP"
[ "$CHECKED" -ge 1 ] || fail "no sealed segment was checked"
pass "recovery left $CHECKED sealed segment(s) byte-identical"
[ "$CHECKED" -ge 1 ] || fail "no sealed segment was verified"
AFTER_SEGMENTS="$(segments_of "$BROKER_PORT")"
AFTER_RECORDS=$(printf '%s\n' "$AFTER_SEGMENTS" | python3 -c 'import sys; print(sum(int(l.split("\t")[1]) for l in sys.stdin if l.strip()))')
# exactly the torn segment's records are gone — no more (recovery stops
# at the tear), no fewer (sealed segments are untouched)
[ "$AFTER_RECORDS" -eq "$((BEFORE_RECORDS - LAST_RECORDS))" ] \
  || fail "recovery lost $((BEFORE_RECORDS - AFTER_RECORDS)) records, expected $LAST_RECORDS"
[ "$AFTER_RECORDS" -gt 0 ] || fail "recovery lost the whole log"
# and what survived still reads
"$EXE" consume --topic "$TOPIC" --from "$(printf '%s\n' "$AFTER_SEGMENTS" | head -1 | cut -f1)" --remote "127.0.0.1:$BROKER_PORT" > /dev/null \
  || fail "the surviving records are not readable after recovery"
pass "a torn tail cost exactly its own segment's $LAST_RECORDS records; sealed segments byte-identical"

# ---- 6. replication across segments ------------------------------------
# two data nodes with rolling on: the follower's segment files must be
# byte-identical to the leader's, per segment — segmentation is part of
# what replication reproduces, not an accident of the local disk
kill "$BROKER_PID" 2>/dev/null || true; wait "$BROKER_PID" 2>/dev/null || true
kill "$FLAT_PID" 2>/dev/null || true; wait "$FLAT_PID" 2>/dev/null || true
BROKER_PID=""; FLAT_PID=""
"$EXE" sc --listen "127.0.0.1:$SC_PORT" --data-dir "$WORK/sc" > "$WORK/sc.log" 2>&1 &
SC_PID=$!
wait_listen "$SC_PORT" || fail "sc did not start"
apply_topic "$WORK/spu-a" "$TOPIC"
apply_topic "$WORK/spu-b" "$TOPIC"
MOONFLUX_RETAIN_BYTES=0 "$EXE" spu --id spu-a --listen "127.0.0.1:$A_PORT" --data-dir "$WORK/spu-a" --sc "127.0.0.1:$SC_PORT" > "$WORK/spu-a.log" 2>&1 &
A_PID=$!
MOONFLUX_RETAIN_BYTES=0 "$EXE" spu --id spu-b --listen "127.0.0.1:$B_PORT" --data-dir "$WORK/spu-b" --sc "127.0.0.1:$SC_PORT" > "$WORK/spu-b.log" 2>&1 &
B_PID=$!
wait_listen "$A_PORT" || fail "spu-a did not start"
wait_listen "$B_PORT" || fail "spu-b did not start"
"$EXE" topic create --name "$TOPIC" --partitions 1 --replication-factor 2 --remote "127.0.0.1:$SC_PORT" > /dev/null \
  || fail "topic create failed"
LEADER=""
for _ in $(seq 1 80); do
  LEADER="$("$EXE" cluster leader --topic "$TOPIC" --remote "127.0.0.1:$SC_PORT" 2>/dev/null || true)"
  [ -n "$LEADER" ] && break
  sleep 0.25
done
[ -n "$LEADER" ] || { cat "$WORK/sc.log"; fail "no leader was assigned"; }
"$EXE" produce --topic "$TOPIC" --file "$WORK/more.txt" --remote "$LEADER" > /dev/null \
  || fail "produce to the leader failed"
LEADER_DIR="$WORK/spu-a"; FOLLOWER_DIR="$WORK/spu-b"
[ "$LEADER" = "127.0.0.1:$B_PORT" ] && LEADER_DIR="$WORK/spu-b" && FOLLOWER_DIR="$WORK/spu-a"
MATCHED=""
for _ in $(seq 1 80); do
  # before the follower has written anything its directory may not
  # exist: that is "not yet", not an error (set -e would otherwise
  # abort the gate mid-wait)
  LEADER_BASES="$(ls "$LEADER_DIR/topics/$TOPIC/partition-0"/*.log 2>/dev/null | xargs -n1 basename 2>/dev/null | sort | tr '\n' ' ' || true)"
  FOLLOWER_BASES="$(ls "$FOLLOWER_DIR/topics/$TOPIC/partition-0"/*.log 2>/dev/null | xargs -n1 basename 2>/dev/null | sort | tr '\n' ' ' || true)"
  if [ -n "$LEADER_BASES" ] && [ "$LEADER_BASES" = "$FOLLOWER_BASES" ]; then
    SAME=yes
    for f in $(ls "$LEADER_DIR/topics/$TOPIC/partition-0"/*.log | xargs -n1 basename); do
      cmp -s "$LEADER_DIR/topics/$TOPIC/partition-0/$f" "$FOLLOWER_DIR/topics/$TOPIC/partition-0/$f" || SAME=""
    done
    [ -n "$SAME" ] && MATCHED=yes && break
  fi
  sleep 0.25
done
[ -n "$MATCHED" ] || {
  ls "$LEADER_DIR/topics/$TOPIC/partition-0" "$FOLLOWER_DIR/topics/$TOPIC/partition-0"
  continue_msg="follower segments differ from the leader's"
  fail "$continue_msg"
}
pass "the follower's segment files are byte-identical to the leader's, per segment"

echo "E2E-P8-STORAGE: all green"
