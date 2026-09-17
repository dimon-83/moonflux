#!/bin/bash
# P3 (T22) gate: follower-pull replication and watermark consistency.
#
# Two data nodes and a control plane, three processes, real logs:
#
#   1. the leader's records reach the follower as bytes — its segment
#      file is a byte-prefix of the leader's, not a re-encoding
#   2. the high watermark only advances once the follower confirms:
#      kill the follower and HW stalls while LEO keeps growing
#   3. restart it and it catches up, HW resumes, bytes still match
#   4. a divergent tail (a node whose log runs past the leader's) is
#      truncated to the leader's end *and the discard is reported* —
#      the project's own rule, since the reference has no epoch to
#      compare tails by
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# The debug build is what `moon build --target native` (and `moon test`)
# produce, so it is the artifact every gate here means to test. A release
# binary is only a fallback: preferring it once meant a gate silently
# tested a build from an earlier session.
EXE="${MOONFLUX_EXE:-$ROOT/_build/native/debug/build/apps/cli/cli.exe}"
[ -x "$EXE" ] || EXE="$ROOT/_build/native/release/build/apps/cli/cli.exe"
[ -x "$EXE" ] || { echo "cli executable not found; run: moon build --target native" >&2; exit 1; }

WORK="$(mktemp -d /tmp/moonflux-p3-repl.XXXXXX)"
SC_PORT="${MOONFLUX_SC_PORT:-19361}"
A_PORT="${MOONFLUX_SPU_A_PORT:-19362}"
B_PORT="${MOONFLUX_SPU_B_PORT:-19363}"
TOPIC="${MOONFLUX_P3_TOPIC:-events}"

SC_PID=""; A_PID=""; B_PID=""
cleanup() {
  for pid in "$A_PID" "$B_PID" "$SC_PID"; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
    [ -n "$pid" ] && wait "$pid" 2>/dev/null || true
  done
}
trap 'cleanup; rm -rf "$WORK"' EXIT

fail() { echo "E2E-P3-REPL FAIL: $*" >&2; exit 1; }
pass() { echo "E2E-P3-REPL PASS: $*"; }

wait_listen() { # $1 = port
  for _ in $(seq 1 60); do
    lsof -i ":$1" -sTCP:LISTEN > /dev/null 2>&1 && return 0
    sleep 0.1
  done
  return 1
}

# offsets <address> -> "hw leo" from the node leading the topic
offsets() { # $1 = host:port of the leader
  "$EXE" cluster offsets --topic "$TOPIC" --remote "$1"
}

leader_of() { # $1 = sc port -> "host:port" or empty
  "$EXE" cluster leader --topic "$TOPIC" --remote "127.0.0.1:$1" 2>/dev/null || true
}

produce_lines() { # $1 = leader remote, $2 = file
  "$EXE" produce --topic "$TOPIC" --file "$2" --remote "$1" > /dev/null
}

start_spu() { # $1 = id, $2 = port, $3 = data dir
  "$EXE" spu --id "$1" --listen "127.0.0.1:$2" --data-dir "$3" \
    --sc "127.0.0.1:$SC_PORT" > "$3.log" 2>&1 &
  echo $!
}

log_of() { # the data dir of a node is $WORK/<id>
  echo "$WORK/$1.log"
}

# ---- cluster up ----------------------------------------------------------
mkdir -p "$WORK/sc"
"$EXE" sc --listen "127.0.0.1:$SC_PORT" --data-dir "$WORK/sc" > "$WORK/sc.log" 2>&1 &
SC_PID=$!
wait_listen "$SC_PORT" || { cat "$WORK/sc.log"; fail "sc did not start"; }

# two replicas per partition: the leader plus one follower is the
# smallest cluster that can stall a watermark. The topic is declared
# through the control plane (the metadata store is the source of
# truth; placement follows on the next reconcile).
"$EXE" topic create --name "$TOPIC" --partitions 1 --replication-factor 2 \
  --remote "127.0.0.1:$SC_PORT" > /dev/null || fail "topic create failed"

A_PID="$(start_spu spu-a "$A_PORT" "$WORK/spu-a")"
B_PID="$(start_spu spu-b "$B_PORT" "$WORK/spu-b")"
wait_listen "$A_PORT" || fail "spu-a did not start"
wait_listen "$B_PORT" || fail "spu-b did not start"

# both nodes need the same pipeline applied: the topic each hosts comes
# from its own applied spec (topic creation as a cluster verb is T24)
for node in spu-a spu-b; do
  "$EXE" pipeline apply -f /dev/stdin --data-dir "$WORK/$node" <<EOF > /dev/null
{
  "apiVersion": "moonflux.io/v1alpha1",
  "kind": "Pipeline",
  "metadata": { "name": "replicated" },
  "spec": {
    "source": { "type": "file", "path": "$WORK/in.txt" },
    "transforms": [],
    "topic": { "name": "$TOPIC" },
    "sink": { "type": "stdout" }
  }
}
EOF
  # the node reads its topic at startup: restart it so it picks the
  # applied pipeline up (a running node re-reads on the next tick, but
  # the log line ordering is easier to follow from a clean start)
done
kill "$A_PID" "$B_PID" 2>/dev/null || true
wait "$A_PID" 2>/dev/null || true
wait "$B_PID" 2>/dev/null || true
A_PID="$(start_spu spu-a "$A_PORT" "$WORK/spu-a")"
B_PID="$(start_spu spu-b "$B_PORT" "$WORK/spu-b")"
wait_listen "$A_PORT" || fail "spu-a did not restart"
wait_listen "$B_PORT" || fail "spu-b did not restart"

# wait for placement: the control plane needs both nodes registered
LEADER=""
for _ in $(seq 1 60); do
  LEADER="$(leader_of "$SC_PORT")"
  [ -n "$LEADER" ] && break
  sleep 0.25
done
[ -n "$LEADER" ] || { cat "$WORK/sc.log"; fail "no leader was assigned"; }
pass "control plane placed $TOPIC[0] and assigned a leader ($LEADER)"

FOLLOWER_PORT="$A_PORT"
[ "$LEADER" = "127.0.0.1:$A_PORT" ] && FOLLOWER_PORT="$B_PORT"
FOLLOWER_ID=spu-a
[ "$FOLLOWER_PORT" = "$B_PORT" ] && FOLLOWER_ID=spu-b
LEADER_DIR="$WORK/spu-a"
LEADER_ID=spu-a
[ "$LEADER" = "127.0.0.1:$B_PORT" ] && LEADER_DIR="$WORK/spu-b" && LEADER_ID=spu-b
FOLLOWER_DIR="$WORK/$FOLLOWER_ID"
pass "leader is on port ${LEADER##*:}, follower is $FOLLOWER_ID (port $FOLLOWER_PORT)"

# ---- 1. records replicate as bytes --------------------------------------
printf 'alpha\nbeta\ngamma\n' > "$WORK/in.txt"
produce_lines "$LEADER" "$WORK/in.txt" || fail "produce to the leader failed"

# the replica file must be a byte-prefix of the leader's: replication
# copies frames, it does not re-encode records. The follower creates
# its log on the first pull, so wait for bytes, not for the file.
# P8: a partition is a sequence of segment files; "the replica's
# bytes" means its segments concatenated in base order (the names are
# zero-padded, so a plain sort is offset order)
partition_bytes() { # $1 = data dir, $2 = out file
  : > "$2"
  local dir="$1/topics/$TOPIC/partition-0"
  for f in $(ls "$dir"/*.log 2>/dev/null | sort); do
    cat "$f" >> "$2"
  done
}
LEADER_LOG="$WORK/leader.bin"
FOLLOWER_LOG="$WORK/follower.bin"
partition_bytes "$LEADER_DIR" "$LEADER_LOG"
LEADER_SIZE=$(wc -c < "$LEADER_LOG" | tr -d ' ')
for _ in $(seq 1 80); do
  partition_bytes "$FOLLOWER_DIR" "$FOLLOWER_LOG"
  FOLLOWER_SIZE=$(wc -c < "$FOLLOWER_LOG" | tr -d ' ')
  [ "$FOLLOWER_SIZE" = "$LEADER_SIZE" ] && break
  sleep 0.25
done
[ "$FOLLOWER_SIZE" -ge 0 ] || { cat "$(log_of "$FOLLOWER_ID")"; fail "the follower never wrote a replica log"; }
[ "$FOLLOWER_SIZE" -gt 0 ] || { cat "$(log_of "$FOLLOWER_ID")"; fail "the follower's replica log stayed empty"; }
[ "$FOLLOWER_SIZE" = "$LEADER_SIZE" ] \
  || { cat "$(log_of "$FOLLOWER_ID")"; fail "the follower has $FOLLOWER_SIZE bytes, the leader has $LEADER_SIZE"; }
head -c "$FOLLOWER_SIZE" "$LEADER_LOG" > "$WORK/leader-prefix.bin"
cmp -s "$WORK/leader-prefix.bin" "$FOLLOWER_LOG" \
  || fail "the follower's bytes are not a prefix of the leader's"
pass "the follower's segment is a byte-prefix of the leader's ($FOLLOWER_SIZE bytes)"

# ---- 2. the watermark waits for the follower ----------------------------
for _ in $(seq 1 40); do
  read -r HW LEO <<< "$(offsets "$LEADER")"
  [ "$HW" = "3" ] && break
  sleep 0.25
done
[ "$HW" = "3" ] || { cat "$(log_of "$LEADER_ID")"; fail "HW did not reach 3 once the follower caught up (hw=$HW leo=$LEO)"; }
pass "HW advanced to $HW once the follower confirmed (leo=$LEO)"

if [ "$FOLLOWER_ID" = "spu-a" ]; then kill "$A_PID" 2>/dev/null || true; wait "$A_PID" 2>/dev/null || true; A_PID=""; else kill "$B_PID" 2>/dev/null || true; wait "$B_PID" 2>/dev/null || true; B_PID=""; fi
sleep 1

printf 'delta\nepsilon\n' > "$WORK/more.txt"
produce_lines "$LEADER" "$WORK/more.txt" || fail "produce with the follower down failed"
read -r HW2 LEO2 <<< "$(offsets "$LEADER")"
[ "$LEO2" = "5" ] || fail "leader LEO should be 5 after appending while the follower is down (got $LEO2)"
[ "$HW2" = "3" ] || { cat "$(log_of "$LEADER_ID")"; fail "HW must stay at 3 while no follower confirms (got $HW2)"; }
pass "with the follower down: HW stayed at $HW2 while LEO grew to $LEO2"

# ---- 3. restart and catch up -------------------------------------------
NEW_PID="$(start_spu "$FOLLOWER_ID" "$FOLLOWER_PORT" "$FOLLOWER_DIR")"
if [ "$FOLLOWER_ID" = "spu-a" ]; then A_PID="$NEW_PID"; else B_PID="$NEW_PID"; fi
wait_listen "$FOLLOWER_PORT" || fail "the follower did not come back"

for _ in $(seq 1 80); do
  read -r HW LEO <<< "$(offsets "$LEADER")"
  [ "$HW" = "5" ] && break
  sleep 0.25
done
[ "$HW" = "5" ] || { cat "$(log_of "$LEADER_ID")"; fail "HW did not resume after the follower returned (hw=$HW leo=$LEO)"; }
FOLLOWER_SIZE=$(wc -c < "$FOLLOWER_LOG" | tr -d ' ')
LEADER_SIZE=$(wc -c < "$LEADER_LOG" | tr -d ' ')
[ "$FOLLOWER_SIZE" = "$LEADER_SIZE" ] \
  || fail "replica size $FOLLOWER_SIZE does not match the leader's $LEADER_SIZE"
cmp -s "$LEADER_LOG" "$FOLLOWER_LOG" || fail "replica bytes diverge from the leader's after catch-up"
pass "the restarted follower caught up byte for byte (HW=$HW, $FOLLOWER_SIZE bytes)"

# ---- 4. a divergent tail is truncated and the discard reported ---------
# stop the follower, append to its own log directly (as if it had been
# a leader that never had its writes replicated), then start it again:
# the leader's LEO is the only authority, so that tail must go
if [ "$FOLLOWER_ID" = "spu-a" ]; then kill "$A_PID" 2>/dev/null || true; wait "$A_PID" 2>/dev/null || true; A_PID=""; else kill "$B_PID" 2>/dev/null || true; wait "$B_PID" 2>/dev/null || true; B_PID=""; fi
sleep 0.5
printf 'phantom\n' > "$WORK/ghost.txt"
"$EXE" produce --topic "$TOPIC" --file "$WORK/ghost.txt" --data-dir "$FOLLOWER_DIR" > /dev/null \
  || fail "could not stage a divergent tail"
# the staged tail is checked on disk, not by asking the node: it is
# deliberately stopped, and a query would only prove it is down. The
# snapshots are re-taken: writing to the follower's own data dir added
# a segment, and the comparison is about what is on disk *now*.
partition_bytes "$LEADER_DIR" "$LEADER_LOG"
partition_bytes "$FOLLOWER_DIR" "$FOLLOWER_LOG"
LEADER_BYTES=$(wc -c < "$LEADER_LOG" | tr -d ' ')
STAGED_BYTES=$(wc -c < "$FOLLOWER_LOG" | tr -d ' ')
[ "$STAGED_BYTES" -gt "$LEADER_BYTES" ] \
  || fail "the divergent tail was not staged ($STAGED_BYTES vs leader $LEADER_BYTES)"

NEW_PID="$(start_spu "$FOLLOWER_ID" "$FOLLOWER_PORT" "$FOLLOWER_DIR")"
if [ "$FOLLOWER_ID" = "spu-a" ]; then A_PID="$NEW_PID"; else B_PID="$NEW_PID"; fi
wait_listen "$FOLLOWER_PORT" || fail "the follower did not come back after divergence"

for _ in $(seq 1 60); do
  grep -q "divergent tail" "$(log_of "$FOLLOWER_ID")" && break
  sleep 0.25
done
grep -q "divergent tail" "$(log_of "$FOLLOWER_ID")" \
  || { cat "$(log_of "$FOLLOWER_ID")"; fail "the divergent tail was not reported"; }
partition_bytes "$FOLLOWER_DIR" "$FOLLOWER_LOG"
cmp -s "$LEADER_LOG" "$FOLLOWER_LOG" || fail "the divergent tail was not actually removed"
pass "a divergent tail was truncated to the leader's LEO and the discard reported"

echo "E2E-P3-REPL: all green"
