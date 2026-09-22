#!/usr/bin/env bash
# E2E-P16: the process keeps its open logs.
#
# Opening a log recovers the tail — a scan of the last segment, by
# design — and every request used to pay it. The consequence was not
# "a bit slower": a data node rescanning a 12 MiB segment per 512-record
# replication round spent its tick budget there, missed its heartbeat
# window, and the control plane declared it offline (measured while
# building the P15 gate).
#
# What this gate falsifies is a *count* and a *symptom*, not a stopwatch:
#
#   1. thirteen requests across several segments open the partition's
#      log exactly once
#   2. with the cache switched off the same traffic opens it per
#      request — so leg 1 is measuring the cache, not luck
#   3. eviction (a one-entry cache, two topics) is safe: the evicted
#      topic reads back correctly after being reopened
#   4. retention deletes whole segments *through the cached handle*:
#      reads above the new floor are exact, below it a structured
#      refusal
#   5. a 12 MiB batch replicates to hw == leo with no "is offline" and
#      no election at the control plane, one open per node
#   6. compaction rewrites segments through the cached handles and
#      leaves both replicas byte-identical, with the superseded records
#      actually gone
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXE="${MOONFLUX_EXE:-$ROOT/_build/native/debug/build/apps/cli/cli.exe}"
[ -x "$EXE" ] || EXE="$ROOT/_build/native/release/build/apps/cli/cli.exe"
[ -x "$EXE" ] || {
  echo "cli executable not found; run: moon build --target native" >&2
  exit 1
}

WORK="$(mktemp -d /tmp/moonflux-p16-logcache.XXXXXX)"
BROKER_PORT="${MOONFLUX_P16_BROKER_PORT:-19601}"
RETENTION_PORT="${MOONFLUX_P16_RETENTION_PORT:-19602}"
EVICT_PORT="${MOONFLUX_P16_EVICT_PORT:-19603}"
SC_PORT="${MOONFLUX_P16_SC_PORT:-19604}"
A_PORT="${MOONFLUX_P16_A_PORT:-19605}"
B_PORT="${MOONFLUX_P16_B_PORT:-19606}"
TOPIC="${MOONFLUX_P16_TOPIC:-cached}"

# rolling is on for the standalone legs: a cached handle that only
# worked while everything lived in one segment would prove nothing
export MOONFLUX_ROLL_BYTES="${MOONFLUX_P16_ROLL_BYTES:-4096}"
export MOONFLUX_INDEX_EVERY="${MOONFLUX_P16_INDEX_EVERY:-64}"
export MOONFLUX_RETAIN_BYTES=0
export MOONFLUX_RETAIN_MS=0

PIDS=()
cleanup() {
  for pid in ${PIDS[@]:-}; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
  done
  wait 2>/dev/null || true
}
trap 'cleanup; rm -rf "$WORK"' EXIT

fail() { echo "E2E-P16 FAIL: $*" >&2; exit 1; }
pass() { echo "E2E-P16 PASS: $*"; }

for port in "$BROKER_PORT" "$RETENTION_PORT" "$EVICT_PORT" "$SC_PORT" "$A_PORT" "$B_PORT"; do
  if lsof -i ":$port" -sTCP:LISTEN > /dev/null 2>&1; then
    fail "port $port is already in use"
  fi
done

wait_listen() { # $1 = port
  for _ in $(seq 1 60); do
    lsof -i ":$1" -sTCP:LISTEN > /dev/null 2>&1 && return 0
    sleep 0.1
  done
  return 1
}

gen_lines() { # $1 = path, $2 = lines, $3 = value bytes, $4 = char
  python3 - "$1" "$2" "$3" "$4" <<'PY'
import sys
path, lines, width, ch = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
row = ch * width
with open(path, "w") as fh:
    for _ in range(lines):
        fh.write("%s\n" % row)
PY
}

stop() { # $1 = pid
  kill "$1" 2>/dev/null || true
  wait "$1" 2>/dev/null || true
}

start_broker() { # $1 = port, $2 = data dir, rest = env assignments
  local port="$1" dir="$2"
  shift 2
  env "$@" "$EXE" serve --data-dir "$dir" --listen "127.0.0.1:$port" \
    > "$dir.log" 2>&1 &
  echo $!
}

opened() { # $1 = log file, $2 = topic -> how many times its log was opened
  grep -c "opened $2\[0\]" "$1" || true
}

# ---- 1. thirteen requests, one open -------------------------------------
mkdir -p "$WORK/one"
BROKER="$(start_broker "$BROKER_PORT" "$WORK/one")"
PIDS+=("$BROKER")
wait_listen "$BROKER_PORT" || { cat "$WORK/one.log"; fail "serve did not start"; }

gen_lines "$WORK/rows.txt" 12 200 "r"
for i in $(seq 1 12); do
  "$EXE" produce --topic "$TOPIC" --file "$WORK/rows.txt" \
    --remote "127.0.0.1:$BROKER_PORT" > /dev/null ||
    fail "produce round $i failed"
done
"$EXE" consume --topic "$TOPIC" --remote "127.0.0.1:$BROKER_PORT" > "$WORK/remote.txt" ||
  fail "the drain failed"
"$EXE" consume --topic "$TOPIC" --data-dir "$WORK/one" > "$WORK/local.txt" 2> "$WORK/local.err" ||
  fail "the local read failed"
cmp "$WORK/remote.txt" "$WORK/local.txt" ||
  fail "the remote read differs from the local read (a diagnostic on stdout?)"

OPENS="$(opened "$WORK/one.log" "$TOPIC")"
[ "$OPENS" = "1" ] ||
  { grep "opened $TOPIC" "$WORK/one.log" | head -5; fail "144 records over 13 requests opened the log $OPENS time(s), not once"; }
# the log really did roll under the cached handle: ask the partition, not
# the open line (which is a snapshot from before the writes)
SEGMENTS="$("$EXE" cluster segments --topic "$TOPIC" --partition 0 --remote "127.0.0.1:$BROKER_PORT" |
  wc -l | tr -d ' ')"
[ "${SEGMENTS:-0}" -ge 2 ] ||
  fail "the traffic did not cross a segment boundary (${SEGMENTS:-0} segment(s)); rolling is what makes this leg mean anything"
pass "1: 13 requests over $SEGMENTS segments opened $TOPIC[0] exactly once ($(wc -l < "$WORK/remote.txt" | tr -d ' ') records, byte-identical)"
stop "$BROKER"

# ---- 2. the counter measures the cache ----------------------------------
mkdir -p "$WORK/nocache"
BROKER="$(start_broker "$BROKER_PORT" "$WORK/nocache" MOONFLUX_LOG_CACHE=0)"
PIDS+=("$BROKER")
wait_listen "$BROKER_PORT" || fail "serve did not start (cache off)"
for i in $(seq 1 4); do
  "$EXE" produce --topic "$TOPIC" --file "$WORK/rows.txt" \
    --remote "127.0.0.1:$BROKER_PORT" > /dev/null || fail "produce round $i failed (cache off)"
done
"$EXE" consume --topic "$TOPIC" --remote "127.0.0.1:$BROKER_PORT" > "$WORK/nocache.txt" ||
  fail "the drain failed (cache off)"
DISTINCT="$(sort -u "$WORK/nocache.txt" | wc -l | tr -d ' ')"
[ "$DISTINCT" = "48" ] || fail "with the cache off the read returned $DISTINCT distinct lines, not 48"
NOCACHE_OPENS="$(opened "$WORK/nocache.log" "$TOPIC")"
[ "$NOCACHE_OPENS" -ge 5 ] ||
  fail "with MOONFLUX_LOG_CACHE=0 the log was opened only $NOCACHE_OPENS time(s); the counter would not catch a regression"
pass "2: with the cache off the same traffic opened the log $NOCACHE_OPENS times — leg 1 is measuring the cache"
stop "$BROKER"

# ---- 3. eviction is safe ------------------------------------------------
mkdir -p "$WORK/evict"
BROKER="$(start_broker "$EVICT_PORT" "$WORK/evict" MOONFLUX_LOG_CACHE=1)"
PIDS+=("$BROKER")
wait_listen "$EVICT_PORT" || fail "serve did not start (evicting)"
printf 'alpha-1\nalpha-2\n' > "$WORK/alpha.txt"
printf 'beta-1\n' > "$WORK/beta.txt"
"$EXE" produce --topic alpha --file "$WORK/alpha.txt" --remote "127.0.0.1:$EVICT_PORT" > /dev/null ||
  fail "produce alpha failed"
"$EXE" produce --topic beta --file "$WORK/beta.txt" --remote "127.0.0.1:$EVICT_PORT" > /dev/null ||
  fail "produce beta failed"
# alpha's handle was just evicted (the cache holds one entry): asking for
# it again must reopen the same log rather than serve a stale handle
"$EXE" consume --topic alpha --remote "127.0.0.1:$EVICT_PORT" > "$WORK/alpha.out" ||
  fail "the read after eviction failed"
[ "$(cut -f4 "$WORK/alpha.out" | tr '\n' ',')" = "alpha-1,alpha-2," ] ||
  { cat "$WORK/alpha.out"; fail "the evicted topic did not read back correctly"; }
ALPHA_OPENS="$(opened "$WORK/evict.log" alpha)"
[ "$ALPHA_OPENS" = "2" ] ||
  fail "alpha was opened $ALPHA_OPENS time(s); a one-entry cache means open, evict, reopen"
pass "3: a one-entry cache evicts and reopens without losing a record (alpha opened twice)"
stop "$BROKER"

# ---- 4. retention deletes through the cached handle ---------------------
mkdir -p "$WORK/retention"
gen_lines "$WORK/retain.txt" 400 60 "k"
# retention in `serve` runs for the *applied* topic (the broker owns the
# whole log, so its floor is its own end)
"$EXE" pipeline apply -f /dev/stdin --data-dir "$WORK/retention" <<EOF > /dev/null
{
  "apiVersion": "moonflux.io/v1alpha1",
  "kind": "Pipeline",
  "metadata": { "name": "retained" },
  "spec": {
    "source": { "type": "file", "path": "$WORK/retain.txt" },
    "transforms": [],
    "topic": { "name": "kept" },
    "sink": { "type": "stdout" }
  }
}
EOF
BROKER="$(start_broker "$RETENTION_PORT" "$WORK/retention" \
  MOONFLUX_ROLL_BYTES=4096 MOONFLUX_RETAIN_BYTES=8192 MOONFLUX_RETAIN_MS=0)"
PIDS+=("$BROKER")
wait_listen "$RETENTION_PORT" || fail "serve did not start (retention)"
for i in $(seq 1 4); do
  "$EXE" produce --topic kept --file "$WORK/retain.txt" \
    --remote "127.0.0.1:$RETENTION_PORT" > /dev/null || fail "retention produce $i failed"
done
for _ in $(seq 1 20); do
  grep -q "retained away kept\[0\]" "$WORK/retention.log" && break
  sleep 0.5
done
grep -q "retained away kept\[0\]" "$WORK/retention.log" ||
  { tail -5 "$WORK/retention.log"; fail "retention never deleted a segment"; }
FIRST="$(sed -n 's/.*earliest readable offset is now \([0-9]*\).*/\1/p' "$WORK/retention.log" | tail -1)"
[ -n "$FIRST" ] && [ "$FIRST" -gt 0 ] || { cat "$WORK/retention.log"; fail "retention reported no new readable start"; }
"$EXE" consume --topic kept --from "$FIRST" --remote "127.0.0.1:$RETENTION_PORT" \
  > "$WORK/kept.out" || fail "reading from the new start failed"
[ "$(wc -l < "$WORK/kept.out" | tr -d ' ')" -gt 0 ] ||
  fail "reading from the reported start returned nothing"
if "$EXE" consume --topic kept --from 0 --remote "127.0.0.1:$RETENTION_PORT" \
  > "$WORK/gone.out" 2>&1; then
  fail "reading below the retained floor succeeded (it must be a structured refusal)"
fi
grep -qiE "OffsetOutOfRange|out of range" "$WORK/gone.out" ||
  { cat "$WORK/gone.out"; fail "the refusal below the floor did not name the reason"; }
pass "4: retention rewrote the readable range through the cached handle (floor $FIRST; above it exact, below it refused)"
stop "$BROKER"

# ---- 5. a big batch replicates, and nobody is called dead --------------
mkdir -p "$WORK/sc" "$WORK/spu-a" "$WORK/spu-b"
# 2 MiB segments: big enough that the 12 MiB batch is a handful of
# segments, small enough that a 3 MiB keyed write fills one — compaction
# only rewrites *sealed* segments (P14's rule), so the keyed records need
# a segment of their own that a later write can seal
export MOONFLUX_ROLL_BYTES=2097152
export MOONFLUX_INDEX_EVERY=64
"$EXE" sc --listen "127.0.0.1:$SC_PORT" --data-dir "$WORK/sc" > "$WORK/sc.log" 2>&1 &
SC_PID=$!
PIDS+=("$SC_PID")
wait_listen "$SC_PORT" || { cat "$WORK/sc.log"; fail "sc did not start"; }

for node in spu-a spu-b; do
  "$EXE" pipeline apply -f /dev/stdin --data-dir "$WORK/$node" <<EOF > /dev/null
{
  "apiVersion": "moonflux.io/v1alpha1",
  "kind": "Pipeline",
  "metadata": { "name": "cached" },
  "spec": {
    "source": { "type": "file", "path": "$WORK/rows.txt" },
    "transforms": [],
    "topic": { "name": "$TOPIC" },
    "sink": { "type": "stdout" }
  }
}
EOF
done

"$EXE" spu --id spu-a --listen "127.0.0.1:$A_PORT" --data-dir "$WORK/spu-a" \
  --sc "127.0.0.1:$SC_PORT" > "$WORK/spu-a.log" 2>&1 &
A_PID=$!
PIDS+=("$A_PID")
"$EXE" spu --id spu-b --listen "127.0.0.1:$B_PORT" --data-dir "$WORK/spu-b" \
  --sc "127.0.0.1:$SC_PORT" > "$WORK/spu-b.log" 2>&1 &
B_PID=$!
PIDS+=("$B_PID")
wait_listen "$A_PORT" || fail "spu-a did not start"
wait_listen "$B_PORT" || fail "spu-b did not start"

for _ in $(seq 1 80); do
  NODES="$("$EXE" cluster nodes --remote "127.0.0.1:$SC_PORT" 2>/dev/null || true)"
  printf '%s\n' "$NODES" | grep -q spu-a &&
    printf '%s\n' "$NODES" | grep -q spu-b && break
  sleep 0.25
done
printf '%s\n' "$NODES" | grep -q spu-b || { cat "$WORK/sc.log"; fail "nodes did not register"; }

"$EXE" topic create --name "$TOPIC" --partitions 1 --replication-factor 2 \
  --remote "127.0.0.1:$SC_PORT" > /dev/null || fail "topic create failed"

LEADER=""
for _ in $(seq 1 80); do
  LEADER="$("$EXE" cluster leader --topic "$TOPIC" --remote "127.0.0.1:$SC_PORT" 2>/dev/null || true)"
  [ -n "$LEADER" ] && break
  sleep 0.25
done
[ -n "$LEADER" ] || { cat "$WORK/sc.log"; fail "the topic never got a leader"; }
if [ "$LEADER" = "127.0.0.1:$A_PORT" ]; then
  LEADER_NAME="spu-a"; FOLLOWER="127.0.0.1:$B_PORT"; FOLLOWER_NAME="spu-b"
else
  LEADER_NAME="spu-b"; FOLLOWER="127.0.0.1:$A_PORT"; FOLLOWER_NAME="spu-a"
fi

# 12 MiB in 64 KiB records: the sync window's *byte* budget binds (512
# records would be 32 MiB), and a segment this size is exactly what made
# a rescan-per-round node miss its heartbeat window
CLUSTER_LINES=$((12 * 1024 * 1024 / 65536))
gen_lines "$WORK/cluster.txt" "$CLUSTER_LINES" 65535 "c"
"$EXE" produce --topic "$TOPIC" --file "$WORK/cluster.txt" --remote "$LEADER" > /dev/null ||
  fail "the cluster produce failed"

wait_hw() { # $1 = expected hw
  local hw=""
  for _ in $(seq 1 120); do
    hw="$("$EXE" cluster offsets --topic "$TOPIC" --partition 0 --remote "$LEADER" 2>/dev/null |
      awk '{print $1}')"
    [ "$hw" = "$1" ] && return 0
    sleep 0.25
  done
  echo "$hw"
  return 1
}

HW="$(wait_hw "$CLUSTER_LINES")" ||
  { tail -5 "$WORK/sc.log"; fail "replication stalled at hw=$HW of $CLUSTER_LINES"; }
COMPLAINTS="$(grep -cE "is offline|offering $TOPIC" "$WORK/sc.log" || true)"
[ "$COMPLAINTS" = "0" ] ||
  { grep -E "is offline|offering" "$WORK/sc.log"; fail "the control plane doubted a node during replication ($COMPLAINTS complaint(s))"; }
LEADER_OPENS="$(opened "$WORK/$LEADER_NAME.log" "$TOPIC")"
FOLLOWER_OPENS="$(opened "$WORK/$FOLLOWER_NAME.log" "$TOPIC")"
[ "$LEADER_OPENS" = "1" ] || fail "the leader opened its log $LEADER_OPENS time(s)"
[ "$FOLLOWER_OPENS" = "1" ] || fail "the follower opened its log $FOLLOWER_OPENS time(s)"
diff -r "$WORK/$LEADER_NAME/topics/$TOPIC/partition-0" \
  "$WORK/$FOLLOWER_NAME/topics/$TOPIC/partition-0" > /dev/null ||
  fail "the follower's partition is not byte-identical"
pass "5: 12 MiB replicated to hw=$CLUSTER_LINES with no complaint at the control plane (one open each, byte-identical)"

# ---- 6. compaction rewrites through the cached handles -----------------
# Keyed records, all the same key, in a segment of their own — and then
# one more write to seal it. Compaction rewrites only sealed segments
# below the floor (P14), so a leg that leaves them in the active segment
# measures nothing (it did: "0 segment(s) ... 0 records dropped").
KEYED_LINES=15000
awk -v n="$KEYED_LINES" 'BEGIN { v = sprintf("%200s", ""); gsub(/ /, "x", v);
  for (i = 0; i < n; i++) print "k1:" v i }' > "$WORK/keyed.txt"
"$EXE" produce --topic "$TOPIC" --file "$WORK/keyed.txt" --key-separator : \
  --remote "$LEADER" > /dev/null || fail "the keyed produce failed"
printf 'seal\n' > "$WORK/seal.txt"
"$EXE" produce --topic "$TOPIC" --file "$WORK/seal.txt" \
  --remote "$LEADER" > /dev/null || fail "the sealing produce failed"
HW="$(wait_hw "$((CLUSTER_LINES + KEYED_LINES + 1))")" ||
  fail "the keyed records did not replicate (hw=$HW)"

for node in "$LEADER" "$FOLLOWER"; do
  name="$LEADER_NAME"
  [ "$node" = "$FOLLOWER" ] && name="$FOLLOWER_NAME"
  "$EXE" cluster compact --topic "$TOPIC" --partition 0 --remote "$node" \
    > "$WORK/compact-$name.txt" || fail "compaction on $node failed"
done
LEADER_DROPPED="$(grep -oE "[0-9]+ records dropped" "$WORK/compact-$LEADER_NAME.txt" |
  grep -oE "^[0-9]+" || true)"
FOLLOWER_DROPPED="$(grep -oE "[0-9]+ records dropped" "$WORK/compact-$FOLLOWER_NAME.txt" |
  grep -oE "^[0-9]+" || true)"
[ "${LEADER_DROPPED:-0}" = "$((KEYED_LINES - 1))" ] ||
  { cat "$WORK"/compact-*.txt; fail "the leader dropped ${LEADER_DROPPED:-0} of the $((KEYED_LINES - 1)) superseded records"; }
[ "${FOLLOWER_DROPPED:-0}" = "$((KEYED_LINES - 1))" ] ||
  { cat "$WORK"/compact-*.txt; fail "the follower dropped ${FOLLOWER_DROPPED:-0} of the $((KEYED_LINES - 1)) superseded records"; }
diff -r "$WORK/$LEADER_NAME/topics/$TOPIC/partition-0" \
  "$WORK/$FOLLOWER_NAME/topics/$TOPIC/partition-0" > /dev/null ||
  fail "compaction left the replicas different"
CONSUMED="$("$EXE" consume --topic "$TOPIC" --partition 0 --remote "$LEADER" | wc -l | tr -d ' ')"
[ "$CONSUMED" = "$((CLUSTER_LINES + 2))" ] ||
  fail "after compaction the leader served $CONSUMED records, expected $((CLUSTER_LINES + 2)) (keyless, the last k1, and the sealing line)"
pass "6: compaction through the cached handles dropped $LEADER_DROPPED superseded records per replica and kept them byte-identical ($CONSUMED survivors)"

echo "E2E-P16: all green"
