#!/bin/bash
# P7 gate: replication is per partition.
#
# A three-partition topic with replication_factor 2 spread over three
# data nodes. Every leg is about the *partition* being the unit:
#
#   1. placement: each partition has its own leader and replica set
#   2. replication: every partition's followers catch up; hw == leo
#   3. isolation: killing one node stalls the high watermark of the
#      partitions it held and nothing else — the survivor's own
#      partitions keep advancing
#   4. failover: the stalled partitions get a new leader; the healthy
#      one keeps the leader it had
#   5. rejoin: the returning node truncates a divergent tail per
#      partition and reports the discard
#   6. operators see it: `cluster status` prints per-partition
#      leader/replicas/watermarks
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# The debug build is what `moon build --target native` (and `moon test`)
# produce, so it is the artifact every gate here means to test. A release
# binary is only a fallback: preferring it once meant a gate silently
# tested a build from an earlier session.
EXE="${MOONFLUX_EXE:-$ROOT/_build/native/debug/build/apps/cli/cli.exe}"
[ -x "$EXE" ] || EXE="$ROOT/_build/native/release/build/apps/cli/cli.exe"
[ -x "$EXE" ] || { echo "cli executable not found; run: moon build --target native" >&2; exit 1; }

WORK="$(mktemp -d /tmp/moonflux-p7-partitions.XXXXXX)"
SC_PORT="${MOONFLUX_P7_SC_PORT:-19451}"
A_PORT="${MOONFLUX_P7_SPU_A_PORT:-19452}"
B_PORT="${MOONFLUX_P7_SPU_B_PORT:-19453}"
C_PORT="${MOONFLUX_P7_SPU_C_PORT:-19454}"
TOPIC="${MOONFLUX_P7_TOPIC:-events}"
PARTITIONS="${MOONFLUX_P7_PARTITIONS:-3}"
RF="${MOONFLUX_P7_RF:-2}"
SC="127.0.0.1:$SC_PORT"
SC_PID=""; A_PID=""; B_PID=""; C_PID=""
cleanup() {
  for pid in "$A_PID" "$B_PID" "$C_PID" "$SC_PID"; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
    [ -n "$pid" ] && wait "$pid" 2>/dev/null || true
  done
}
trap 'cleanup; rm -rf "$WORK"' EXIT

fail() { echo "E2E-P7-PARTITIONS FAIL: $*" >&2; exit 1; }
pass() { echo "E2E-P7-PARTITIONS PASS: $*"; }

wait_listen() { # $1 = port
  for _ in $(seq 1 60); do
    lsof -i ":$1" -sTCP:LISTEN > /dev/null 2>&1 && return 0
    sleep 0.1
  done
  return 1
}

leader_of() { # $1 = partition index -> "host:port" or ""
  "$EXE" cluster leader --topic "$TOPIC" --partition "$1" --remote "$SC" 2>/dev/null || true
}

offsets_of() { # $1 = address, $2 = partition -> "hw leo"
  "$EXE" cluster offsets --topic "$TOPIC" --partition "$2" --remote "$1" 2>/dev/null || true
}

start_spu() { # $1 = id, $2 = port
  "$EXE" spu --id "$1" --listen "127.0.0.1:$2" --data-dir "$WORK/$1" \
    --sc "$SC" > "$WORK/$1.log" 2>&1 &
  echo $!
}

port_of() { # $1 = address -> port
  printf '%s' "${1##*:}"
}

node_name_of() { # $1 = address -> spu-a|spu-b|spu-c
  case "$(port_of "$1")" in
    "$A_PORT") echo spu-a ;;
    "$B_PORT") echo spu-b ;;
    *) echo spu-c ;;
  esac
}

declare_topic() { # declare (or re-declare) the topic through the control plane
  "$EXE" topic create --name "$TOPIC" --partitions "$PARTITIONS" \
    --replication-factor "$RF" --remote "$SC" > /dev/null
}

# ---- cluster up ---------------------------------------------------------
mkdir -p "$WORK/sc" "$WORK/spu-a" "$WORK/spu-b" "$WORK/spu-c"
"$EXE" sc --listen "$SC" --data-dir "$WORK/sc" > "$WORK/sc.log" 2>&1 &
SC_PID=$!
wait_listen "$SC_PORT" || { cat "$WORK/sc.log"; fail "sc did not start"; }

# the pipeline names the topic every node serves; placement (which
# partitions, on whom) still comes from the control plane
for node in spu-a spu-b spu-c; do
  "$EXE" pipeline apply -f /dev/stdin --data-dir "$WORK/$node" <<EOF > /dev/null
{
  "apiVersion": "moonflux.io/v1alpha1",
  "kind": "Pipeline",
  "metadata": { "name": "partitioned" },
  "spec": {
    "source": { "type": "file", "path": "$WORK/in.txt" },
    "transforms": [],
    "topic": { "name": "$TOPIC" },
    "sink": { "type": "stdout" }
  }
}
EOF
done

# the nodes register first: a topic declared before its nodes exist is
# placed on whatever pool was visible then (placement is sticky until
# the node set changes), and this gate is about a settled cluster
A_PID="$(start_spu spu-a "$A_PORT")"
B_PID="$(start_spu spu-b "$B_PORT")"
C_PID="$(start_spu spu-c "$C_PORT")"
wait_listen "$A_PORT" || fail "spu-a did not start"
wait_listen "$B_PORT" || fail "spu-b did not start"
wait_listen "$C_PORT" || fail "spu-c did not start"
for _ in $(seq 1 80); do
  NODES="$("$EXE" cluster nodes --remote "$SC" 2>/dev/null || true)"
  if printf '%s\n' "$NODES" | grep -q "spu-a" &&
    printf '%s\n' "$NODES" | grep -q "spu-b" &&
    printf '%s\n' "$NODES" | grep -q "spu-c"; then
    break
  fi
  sleep 0.25
done
printf '%s\n' "$NODES" | grep -q "spu-c" || { cat "$WORK/sc.log"; fail "the third node never registered"; }
declare_topic || fail "topic create failed"

# ---- 1. placement is per partition --------------------------------------
LEADERS=()
for p in $(seq 0 $((PARTITIONS - 1))); do
  LEADER=""
  for _ in $(seq 1 80); do
    LEADER="$(leader_of "$p")"
    [ -n "$LEADER" ] && break
    sleep 0.25
  done
  [ -n "$LEADER" ] || { cat "$WORK/sc.log"; fail "no leader for $TOPIC[$p]"; }
  LEADERS+=("$LEADER")
done
printf '%s\n' "${LEADERS[@]}" | sort -u | grep -q . || fail "leaders were not assigned"
# with 2 nodes and 3 partitions the placement must spread: if every
# partition landed on one node the test below would prove nothing
DISTINCT=$(printf '%s\n' "${LEADERS[@]}" | sort -u | wc -l | tr -d ' ')
[ "$DISTINCT" -ge 2 ] || fail "placement did not spread: leaders=${LEADERS[*]}"
pass "each partition has its own leader (${LEADERS[*]})"

# both nodes hold every partition (rf=2 over 2 nodes): wait for the
# adoption the heartbeat reply drives
for _ in $(seq 1 80); do
  ADOPTED=0
  for node in spu-a spu-b spu-c; do
    COUNT=$(grep -c "hosting $TOPIC\[" "$WORK/$node.log" || true)
    [ "$COUNT" -ge 1 ] && ADOPTED=$((ADOPTED + 1))
  done
  [ "$ADOPTED" -eq 3 ] && break
  sleep 0.25
done
for node in spu-a spu-b spu-c; do
  COUNT=$(grep -c "hosting $TOPIC\[" "$WORK/$node.log" || true)
  [ "$COUNT" -ge 1 ] || { cat "$WORK/$node.log"; fail "$node adopted nothing"; }
done
pass "all three nodes adopted the partitions assigned to them"

# ---- 2. every partition replicates --------------------------------------
for p in $(seq 0 $((PARTITIONS - 1))); do
  printf "p${p}-r1\np${p}-r2\n" > "$WORK/in-$p.txt"
  "$EXE" produce --topic "$TOPIC" --partition "$p" --file "$WORK/in-$p.txt" \
    --remote "${LEADERS[$p]}" > /dev/null || fail "produce to $TOPIC[$p] failed"
done
for p in $(seq 0 $((PARTITIONS - 1))); do
  SETTLED=""
  for _ in $(seq 1 80); do
    read -r HW LEO <<< "$(offsets_of "${LEADERS[$p]}" "$p")"
    if [ "$HW" = "2" ] && [ "$LEO" = "2" ]; then SETTLED=yes; break; fi
    sleep 0.25
  done
  [ -n "$SETTLED" ] || fail "$TOPIC[$p] did not settle (hw=$HW leo=$LEO)"
done
pass "all $PARTITIONS partitions replicated and confirmed (hw == leo == 2 each)"

# ---- 2b. the sync link is reused, not redialled ------------------------
# The honest claim of the persistent replication link (P10) is not
# "faster" — that needs a controlled benchmark — but "it does not dial
# per round", which is a structural fact and therefore falsifiable from
# the logs: one dial per followed partition, and further rounds happen
# without another one.
DIALS_BEFORE=$(grep -h -c "sync link to" "$WORK"/spu-*.log | awk '{sum += $1} END {print sum + 0}')
[ "$DIALS_BEFORE" -ge 1 ] || { cat "$WORK"/spu-*.log; fail "no sync link was ever dialled"; }
for p in $(seq 0 $((PARTITIONS - 1))); do
  printf 'p%s-r3\n' "$p" > "$WORK/more-$p.txt"
  "$EXE" produce --topic "$TOPIC" --partition "$p" --file "$WORK/more-$p.txt" \
    --remote "${LEADERS[$p]}" > /dev/null || fail "produce for the link leg failed"
done
LINK_ROUNDS=""
for _ in $(seq 1 80); do
  LINK_ROUNDS=yes
  for p in $(seq 0 $((PARTITIONS - 1))); do
    read -r HW LEO <<< "$(offsets_of "${LEADERS[$p]}" "$p")"
    if [ "$HW" = "$LEO" ] && [ "$LEO" = "3" ]; then
      continue
    fi
    LINK_ROUNDS=""
  done
  [ -n "$LINK_ROUNDS" ] && break
  sleep 0.25
done
[ -n "$LINK_ROUNDS" ] || fail "the new records did not replicate"
DIALS_AFTER=$(grep -h -c "sync link to" "$WORK"/spu-*.log | awk '{sum += $1} END {print sum + 0}')
[ "$DIALS_AFTER" -eq "$DIALS_BEFORE" ] \
  || { grep -h "sync link" "$WORK"/spu-*.log; fail "the sync link was redialled ($DIALS_BEFORE -> $DIALS_AFTER)"; }
pass "the sync link carried further rounds without redialling ($DIALS_AFTER dial(s), reused)"
# the baseline every later leg reasons from: how many records each
# partition holds now (a number that shifts whenever a leg is added, so
# the legs below derive from it instead of hard-coding it)
BASE_LEO="$(offsets_of "${LEADERS[0]}" 0 | cut -d' ' -f2)"
[ -n "$BASE_LEO" ] || fail "could not read the baseline log end"
NEXT_LEO=$((BASE_LEO + 1))

# ---- 3. a dead node stalls only what it held ---------------------------
# With three nodes and replication_factor 2, each partition's replica
# set covers two of them. Killing one node must leave the partitions it
# was not part of advancing, and stall exactly the ones it was part of —
# at the confirmed prefix when it was a follower, and below the new
# leader's end when it was the leader (a silent member of the set is
# enough to hold a watermark back; that is the same rule as P3, seen
# per partition).
STATUS="$("$EXE" cluster status --remote "$SC")"
echo "$STATUS" > "$WORK/status-before.txt"
member_of() { # $1 = partition, $2 = address -> yes/no
  awk -v p="[$1]" -v a="$2" '
    $1 == p {
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^replicas=/) {
          n = split(substr($i, 10), parts, ",")
          for (k = 1; k <= n; k++) if (parts[k] == a) print "yes"
        }
      }
    }' "$WORK/status-before.txt" | head -1
}

BEFORE=()
for p in $(seq 0 $((PARTITIONS - 1))); do BEFORE+=("$(leader_of "$p")"); done
VICTIM="${BEFORE[1]}"
VICTIM_PORT="$(port_of "$VICTIM")"
VICTIM_ID="$(node_name_of "$VICTIM")"
VICTIM_LOG="$WORK/$VICTIM_ID.log"
VICTIM_DATA="$WORK/$VICTIM_ID"
if [ "$VICTIM_PORT" = "$A_PORT" ]; then
  kill "$A_PID" 2>/dev/null || true; wait "$A_PID" 2>/dev/null || true; A_PID=""
elif [ "$VICTIM_PORT" = "$B_PORT" ]; then
  kill "$B_PID" 2>/dev/null || true; wait "$B_PID" 2>/dev/null || true; B_PID=""
else
  kill "$C_PID" 2>/dev/null || true; wait "$C_PID" 2>/dev/null || true; C_PID=""
fi

# liveness is derived from silence, so the control plane needs its
# timeout before it replaces the leaders the dead node held: wait for
# that (and only that — the partitions it merely followed keep theirs)
LEADERS_SETTLED=""
for _ in $(seq 1 80); do
  LEADERS_SETTLED=yes
  for p in $(seq 0 $((PARTITIONS - 1))); do
    L="$(leader_of "$p")"
    if [ -z "$L" ] || [ "$L" = "$VICTIM" ]; then
      LEADERS_SETTLED=""
      break
    fi
  done
  [ -n "$LEADERS_SETTLED" ] && break
  sleep 0.25
done
[ -n "$LEADERS_SETTLED" ] || { cat "$WORK/sc.log"; fail "the dead node is still named as a leader"; }
pass "the control plane replaced the leaders the dead node held (silence, then election)"

# write one more record to every partition through its current leader
for p in $(seq 0 $((PARTITIONS - 1))); do
  L="$(leader_of "$p")"
  [ -n "$L" ] || continue
  printf "p${p}-r3\n" > "$WORK/tail-$p.txt"
  "$EXE" produce --topic "$TOPIC" --partition "$p" --file "$WORK/tail-$p.txt" \
    --remote "$L" > /dev/null || fail "produce to $TOPIC[$p] after the kill failed"
done

# Give the surviving partitions a chance to converge (a write is
# confirmed one heartbeat after it lands), then assert each one's
# verdict. Reading immediately would race the ack and call a healthy
# partition stalled — the assertions below are about where each
# partition *settles*, not about a single instant.
STALLED=0
ADVANCED=0
STALLED_PARTS=""
for p in $(seq 0 $((PARTITIONS - 1))); do
  L="$(leader_of "$p")"
  [ -n "$L" ] || continue
  INVOLVED="$(member_of "$p" "$VICTIM")"
  HW=0; LEO=0
  for _ in $(seq 1 60); do
    read -r HW LEO <<< "$(offsets_of "$L" "$p")"
    [ "$LEO" = "3" ] || { sleep 0.25; continue; }
    if [ "$INVOLVED" != "yes" ] && [ "$HW" = "$NEXT_LEO" ]; then
      break
    fi
    if [ "$INVOLVED" = "yes" ]; then
      # it settles below its own end: that is the stall, not a race
      sleep 0.5
      read -r HW LEO <<< "$(offsets_of "$L" "$p")"
      break
    fi
    sleep 0.25
  done
  [ "$LEO" = "$NEXT_LEO" ] || fail "$TOPIC[$p] leader did not take the new write (leo=$LEO)"
  if [ "$INVOLVED" != "yes" ]; then
    [ "$HW" = "$NEXT_LEO" ] \
      || fail "$TOPIC[$p] did not involve the dead node but stalled (hw=$HW leo=$LEO; baseline $BASE_LEO, expected $NEXT_LEO)"
    ADVANCED=$((ADVANCED + 1))
  else
    # the dead node is in this partition's replica set, so the
    # watermark holds below the end: at the confirmed prefix when it was
    # a follower, below the new leader's end when it was the leader
    [ "$HW" -lt "$NEXT_LEO" ] || fail "$TOPIC[$p] watermark advanced past a silent member (hw=$HW)"
    if [ "${BEFORE[$p]}" != "$VICTIM" ] && [ "$HW" != "$BASE_LEO" ]; then
      fail "$TOPIC[$p] watermark should have stalled at the confirmed prefix $BASE_LEO (hw=$HW)"
    fi
    STALLED=$((STALLED + 1))
    STALLED_PARTS="$STALLED_PARTS $p"
  fi
done
[ "$STALLED" -ge 1 ] || fail "no partition stalled while its replica was down"
[ "$ADVANCED" -ge 1 ] || fail "no partition kept advancing while another stalled"
pass "$STALLED partition(s) stalled (p$STALLED_PARTS) with the replica down, $ADVANCED kept advancing (isolation is per partition)"

# ---- 4. failover per partition -----------------------------------------
MOVED=0
for p in $(seq 0 $((PARTITIONS - 1))); do
  L="$(leader_of "$p")"
  [ "$(port_of "$L")" = "$VICTIM_PORT" ] && fail "$TOPIC[$p] still names the dead node as leader"
  if [ "${BEFORE[$p]}" != "$L" ]; then
    MOVED=$((MOVED + 1))
  fi
done
[ "$MOVED" -ge 1 ] || fail "no partition led by the dead node was replaced"
# the partitions that already had a surviving leader kept it: nothing
# about a neighbour's failure is a reason to re-elect
for p in $(seq 0 $((PARTITIONS - 1))); do
  if [ "${BEFORE[$p]}" != "$VICTIM" ] && [ "${BEFORE[$p]}" != "$(leader_of "$p")" ]; then
    fail "$TOPIC[$p] changed leader needlessly (was ${BEFORE[$p]}, now $(leader_of "$p"))"
  fi
done
pass "$MOVED partition(s) elected replacements; every other leader stayed put"

# ---- 5. rejoin truncates per partition ---------------------------------
# give the returning node a divergent tail: write into its own log
# while it was away, then let it rejoin and watch it cut back to the
# leader's end — reported, never silent
"$EXE" produce --topic "$TOPIC" --partition 0 --file /dev/stdin \
  --data-dir "$VICTIM_DATA" <<< "divergent-1
divergent-2
" > /dev/null

if [ "$VICTIM_PORT" = "$A_PORT" ]; then
  A_PID="$(start_spu spu-a "$A_PORT")"
elif [ "$VICTIM_PORT" = "$B_PORT" ]; then
  B_PID="$(start_spu spu-b "$B_PORT")"
else
  C_PID="$(start_spu spu-c "$C_PORT")"
fi
wait_listen "$VICTIM_PORT" || fail "the returning node did not come back"

TRUNCATED=""
for _ in $(seq 1 80); do
  if grep -q "divergent tail: truncated $TOPIC\[0\]" "$VICTIM_LOG"; then
    TRUNCATED=yes; break
  fi
  sleep 0.25
done
[ -n "$TRUNCATED" ] || { cat "$VICTIM_LOG"; fail "the divergent tail was not reported as truncated"; }
pass "a returning node truncates its divergent tail and reports the discard"

# ---- 6. operators see per-partition truth ------------------------------
STATUS="$("$EXE" cluster status --remote "$SC")"
echo "$STATUS" | grep -q "\[0\] leader=" || { echo "$STATUS"; fail "status lacks per-partition lines"; }
[ "$(echo "$STATUS" | grep -c 'leader=')" -ge "$PARTITIONS" ] \
  || { echo "$STATUS"; fail "status did not list every partition"; }
echo "$STATUS" | grep -q "hw=" || fail "status lacks watermarks"
pass "cluster status lists every partition's leader, replicas and watermarks"

echo "E2E-P7-PARTITIONS: all green"
