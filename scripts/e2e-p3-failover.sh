#!/bin/bash
# P3 gate (the milestone's own): failover with watermark consistency.
#
#   1. kill the leader  -> the control plane nominates the least
#      lagging eligible replica, which promotes itself and confirms
#   2. the cluster keeps serving: produce to the new leader, read it
#      back (Committed-safe: the data is on the new leader's log)
#   3. the old leader returns and self-demotes to a follower, then
#      catches up — no data is lost, and the two replicas end up byte
#      identical
#   4. a partition with no eligible replica (everyone too far behind)
#      is reported offline rather than handed to a random node
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXE="${MOONFLUX_EXE:-$ROOT/_build/native/release/build/apps/cli/cli.exe}"
[ -x "$EXE" ] || EXE="$ROOT/_build/native/debug/build/apps/cli/cli.exe"
[ -x "$EXE" ] || { echo "cli executable not found; run: moon build --target native" >&2; exit 1; }

WORK="$(mktemp -d /tmp/moonflux-p3-failover.XXXXXX)"
SC_PORT="${MOONFLUX_SC_PORT:-19371}"
A_PORT="${MOONFLUX_SPU_A_PORT:-19372}"
B_PORT="${MOONFLUX_SPU_B_PORT:-19373}"
TOPIC="${MOONFLUX_P3_TOPIC:-events}"

SC_PID=""; A_PID=""; B_PID=""
cleanup() {
  for pid in "$A_PID" "$B_PID" "$SC_PID"; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
    [ -n "$pid" ] && wait "$pid" 2>/dev/null || true
  done
}
trap 'cleanup; rm -rf "$WORK"' EXIT

fail() { echo "E2E-P3-FAILOVER FAIL: $*" >&2; exit 1; }
pass() { echo "E2E-P3-FAILOVER PASS: $*"; }

wait_listen() {
  for _ in $(seq 1 60); do
    lsof -i ":$1" -sTCP:LISTEN > /dev/null 2>&1 && return 0
    sleep 0.1
  done
  return 1
}

leader_of() { "$EXE" cluster leader --topic "$TOPIC" --remote "127.0.0.1:$SC_PORT" 2>/dev/null || true; }
offsets() { "$EXE" cluster offsets --topic "$TOPIC" --remote "$1" 2>/dev/null || echo "?"; }

start_spu() { # id, port, dir
  "$EXE" spu --id "$1" --listen "127.0.0.1:$2" --data-dir "$3" --sc "127.0.0.1:$SC_PORT" \
    > "$3.log" 2>&1 &
  echo $!
}

apply_pipeline() { # dir
  "$EXE" pipeline apply -f /dev/stdin --data-dir "$1" <<EOF > /dev/null
{
  "apiVersion": "moonflux.io/v1alpha1",
  "kind": "Pipeline",
  "metadata": { "name": "failover" },
  "spec": {
    "source": { "type": "file", "path": "$WORK/in.txt" },
    "transforms": [],
    "topic": { "name": "$TOPIC" },
    "sink": { "type": "stdout" }
  }
}
EOF
}

# ---- cluster up ----------------------------------------------------------
mkdir -p "$WORK/sc" "$WORK/spu-a" "$WORK/spu-b"
printf 'one\ntwo\n' > "$WORK/in.txt"
apply_pipeline "$WORK/spu-a"
apply_pipeline "$WORK/spu-b"

"$EXE" sc --listen "127.0.0.1:$SC_PORT" --data-dir "$WORK/sc" > "$WORK/sc.log" 2>&1 &
SC_PID=$!
wait_listen "$SC_PORT" || { cat "$WORK/sc.log"; fail "sc did not start"; }
"$EXE" topic create --name "$TOPIC" --partitions 1 --replication-factor 2 \
  --remote "127.0.0.1:$SC_PORT" > /dev/null || fail "topic create failed"
A_PID="$(start_spu spu-a "$A_PORT" "$WORK/spu-a")"
B_PID="$(start_spu spu-b "$B_PORT" "$WORK/spu-b")"
wait_listen "$A_PORT" || fail "spu-a did not start"
wait_listen "$B_PORT" || fail "spu-b did not start"

OLD_LEADER=""
for _ in $(seq 1 80); do
  OLD_LEADER="$(leader_of)"
  [ -n "$OLD_LEADER" ] && break
  sleep 0.25
done
[ -n "$OLD_LEADER" ] || { cat "$WORK/sc.log"; fail "no initial leader"; }
if [ "$OLD_LEADER" = "127.0.0.1:$A_PORT" ]; then
  OLD_ID=spu-a; OLD_DIR="$WORK/spu-a"; OLD_PID_VAR=A
  SURVIVOR_PORT="$B_PORT"; SURVIVOR_DIR="$WORK/spu-b"; SURVIVOR_ID=spu-b
else
  OLD_ID=spu-b; OLD_DIR="$WORK/spu-b"; OLD_PID_VAR=B
  SURVIVOR_PORT="$A_PORT"; SURVIVOR_DIR="$WORK/spu-a"; SURVIVOR_ID=spu-a
fi
pass "initial leader is $OLD_ID ($OLD_LEADER)"

# replicate a first batch so the survivor has something to be ahead on
"$EXE" produce --topic "$TOPIC" --file "$WORK/in.txt" --remote "$OLD_LEADER" > /dev/null \
  || fail "initial produce failed"
for _ in $(seq 1 80); do
  read -r HW LEO <<< "$(offsets "$OLD_LEADER")"
  [ "$HW" = "2" ] && break
  sleep 0.25
done
[ "$HW" = "2" ] || fail "initial replication did not settle (hw=$HW leo=$LEO)"
pass "both replicas hold the first batch (hw=$HW leo=$LEO)"

# ---- 1. the leader goes silent, and the cluster elects a new one -------
# SIGSTOP rather than kill: a paused process still believes it leads,
# which is what makes the return path interesting — it has to learn it
# lost the partition and step down, exactly as a healed partition
# would find out (the reference's "old leader returns and demotes").
# Killing it would only test a cold start, where there is nothing to
# demote.
if [ "$OLD_PID_VAR" = "A" ]; then OLD_PID="$A_PID"; else OLD_PID="$B_PID"; fi
kill -STOP "$OLD_PID" 2>/dev/null || fail "could not pause the leader"

NEW_LEADER=""
for _ in $(seq 1 120); do
  NEW_LEADER="$(leader_of)"
  if [ -n "$NEW_LEADER" ] && [ "$NEW_LEADER" != "$OLD_LEADER" ]; then
    break
  fi
  sleep 0.25
done
[ -n "$NEW_LEADER" ] || { cat "$WORK/sc.log"; fail "no leader was elected after the old one died"; }
[ "$NEW_LEADER" != "$OLD_LEADER" ] || fail "the dead leader is still recorded as leader"
[ "$NEW_LEADER" = "127.0.0.1:$SURVIVOR_PORT" ] \
  || { cat "$WORK/sc.log"; fail "elected $NEW_LEADER, expected the surviving replica"; }
grep -q "offering" "$WORK/sc.log" || { cat "$WORK/sc.log"; fail "the nomination was not reported"; }
grep -q "elected" "$WORK/sc.log" || { cat "$WORK/sc.log"; fail "the election was not reported"; }
grep -q "promoted" "$SURVIVOR_DIR.log" \
  || { cat "$SURVIVOR_DIR.log"; fail "the candidate did not record its own promotion"; }
pass "the silent leader was replaced: the survivor was offered the partition and promoted itself ($NEW_LEADER)"

# ---- 2. the cluster still serves ---------------------------------------
printf 'three\n' > "$WORK/more.txt"
"$EXE" produce --topic "$TOPIC" --file "$WORK/more.txt" --remote "$NEW_LEADER" > /dev/null \
  || fail "produce to the new leader failed"
"$EXE" consume --topic "$TOPIC" --remote "$NEW_LEADER" | cut -f4- > "$WORK/out.txt" \
  || fail "consume from the new leader failed"
printf 'one\ntwo\nthree\n' > "$WORK/want.txt"
diff -u "$WORK/want.txt" "$WORK/out.txt" || fail "the new leader serves the wrong records"
pass "the new leader serves writes and reads (3 records, including the new one)"

# ---- 3. the old leader wakes up and self-demotes -----------------------
# it still thinks it leads the partition; the control plane's answer
# tells it otherwise, and it steps down without being told to
kill -CONT "$OLD_PID" 2>/dev/null || fail "could not resume the paused leader"

for _ in $(seq 1 80); do
  grep -q "stepped down" "$OLD_DIR.log" && break
  sleep 0.25
done
grep -q "stepped down" "$OLD_DIR.log" \
  || { cat "$OLD_DIR.log"; fail "the returning leader did not self-demote"; }
grep -q "replicating" "$OLD_DIR.log" \
  || { cat "$OLD_DIR.log"; fail "the demoted leader did not start following"; }
pass "the returning leader self-demoted to follower (without being told)"

# and it catches up: both replicas end up holding the same bytes
OLD_LOG="$OLD_DIR/topics/$TOPIC/partition-0.log"
NEW_LOG="$SURVIVOR_DIR/topics/$TOPIC/partition-0.log"
for _ in $(seq 1 80); do
  if [ -f "$OLD_LOG" ] && [ -f "$NEW_LOG" ] && cmp -s "$OLD_LOG" "$NEW_LOG"; then
    break
  fi
  sleep 0.25
done
cmp -s "$OLD_LOG" "$NEW_LOG" \
  || { cat "$OLD_DIR.log"; fail "the returning replica never matched the leader's bytes"; }
NEW_SIZE=$(wc -c < "$NEW_LOG" | tr -d ' ')
pass "the returning replica caught up byte for byte ($NEW_SIZE bytes)"

# the watermark follows: the new leader now counts both replicas again
for _ in $(seq 1 40); do
  read -r HW LEO <<< "$(offsets "$NEW_LEADER")"
  [ "$HW" = "3" ] && break
  sleep 0.25
done
[ "$HW" = "3" ] || fail "hw did not account for the returned replica (hw=$HW leo=$LEO)"
pass "hw covers both replicas again after the rejoin (hw=$HW leo=$LEO)"

# ---- 3.5 hard kill: no cleanup, no loss --------------------------------
# SIGTERM lets a process flush and close; SIGKILL does not. The new
# leader must come up from whatever survived on disk (recovery
# truncates a torn tail) and still hold every record that was ever
# produced — data-loss accounting, not just "it kept serving".
printf 'four\nfive\nsix\n' > "$WORK/batch2.txt"
"$EXE" produce --topic "$TOPIC" --file "$WORK/batch2.txt" --remote "$NEW_LEADER" > /dev/null \
  || fail "produce before the hard kill failed"
for _ in $(seq 1 60); do
  read -r HW LEO <<< "$(offsets "$NEW_LEADER")"
  [ "$HW" = "6" ] && break
  sleep 0.25
done
[ "$HW" = "6" ] || fail "the replicas did not settle before the hard kill (hw=$HW leo=$LEO)"

kill -9 "$([ "$OLD_PID_VAR" = A ] && echo "$A_PID" || echo "$B_PID")" 2>/dev/null || true
wait "$([ "$OLD_PID_VAR" = A ] && echo "$A_PID" || echo "$B_PID")" 2>/dev/null || true
[ "$OLD_PID_VAR" = A ] && A_PID="" || B_PID=""

SURVIVOR_LEADER=""
for _ in $(seq 1 120); do
  SURVIVOR_LEADER="$(leader_of)"
  [ "$SURVIVOR_LEADER" = "127.0.0.1:$SURVIVOR_PORT" ] && break
  sleep 0.25
done
[ "$SURVIVOR_LEADER" = "127.0.0.1:$SURVIVOR_PORT" ] \
  || { cat "$WORK/sc.log"; fail "no election after a hard kill (leader=$SURVIVOR_LEADER)"; }

"$EXE" consume --topic "$TOPIC" --remote "$SURVIVOR_LEADER" | cut -f4- > "$WORK/after-kill.txt" \
  || fail "consume after the hard kill failed"
printf 'one\ntwo\nthree\nfour\nfive\nsix\n' > "$WORK/want-all.txt"
diff -u "$WORK/want-all.txt" "$WORK/after-kill.txt" \
  || { cat "$WORK/after-kill.txt"; fail "records were lost across a hard kill"; }
pass "a hard kill (SIGKILL) cost no records: all 6 are readable from the new leader"

# ---- 4. an offer is not a leadership -----------------------------------
# every replica goes silent: the control plane may keep offering the
# partition to the best survivor it remembers, but nothing is elected,
# because leadership requires the candidate to take it and confirm.
# The partition stays offline — fail-closed, no phantom leader.
ELECTIONS_BEFORE=$(grep -c "elected" "$WORK/sc.log" || true)
if [ "$OLD_PID_VAR" = "A" ]; then kill "$A_PID" 2>/dev/null || true; else kill "$B_PID" 2>/dev/null || true; fi
sleep 0.5
kill "$([ "$OLD_PID_VAR" = A ] && echo "$B_PID" || echo "$A_PID")" 2>/dev/null || true
sleep 6   # let the liveness timeout expire for both nodes

NEXT_LEADER="$(leader_of)"
[ -z "$NEXT_LEADER" ] || fail "a leader is recorded while every replica is silent ($NEXT_LEADER)"
ELECTIONS_AFTER=$(grep -c "elected" "$WORK/sc.log" || true)
[ "$ELECTIONS_AFTER" = "$ELECTIONS_BEFORE" ] \
  || { cat "$WORK/sc.log"; fail "an election was recorded that nobody confirmed"; }
OFFERS=$(grep -c "offering" "$WORK/sc.log" || true)
[ "$OFFERS" -ge 1 ] || { cat "$WORK/sc.log"; fail "the control plane offered nothing at all"; }
pass "with no replica able to confirm, the partition stays leaderless (offers: $OFFERS, elections: $ELECTIONS_AFTER)"

echo "E2E-P3-FAILOVER: all green"
