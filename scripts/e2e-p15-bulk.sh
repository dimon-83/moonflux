#!/usr/bin/env bash
# E2E-P15: the payload budget — the data path, past one buffer's worth.
#
# Before this phase the platform could not move more than 8 MiB: the
# hub's hand-written inbox/outbox caps sat *below* the 16 MiB batch the
# decoder accepts, a big produce died as "connection reset by peer"
# with nothing in the server log, and a big fetch was dropped mid-write
# ("peer is not reading"). Both directions were silent data loss. The
# fix makes one budget (the protocol's batch limit) govern every hop.
#
# Standalone:
#   1 a 20 MiB file produces and drains back byte-identical to the local
#     read — past the 8 MiB write cap and the 8 MiB reply cap both
#   2 offsets stay contiguous across produce chunks: --from N is exact
#   3 one record over the per-field limit is refused *by name* in the
#     producer's own process, and the broker keeps serving
#   4 a frame over the transport's budget is refused loudly: the server
#     reports it and survives, instead of resetting silently
#
# Cluster:
#   5 a 12 MiB batch replicates: the follower's partition directory is a
#     byte-exact copy of the leader's, caught up under a bounded window
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXE="${MOONFLUX_EXE:-$ROOT/_build/native/debug/build/apps/cli/cli.exe}"
[ -x "$EXE" ] || EXE="$ROOT/_build/native/release/build/apps/cli/cli.exe"
[ -x "$EXE" ] || {
  echo "cli executable not found; run: moon build --target native" >&2
  exit 1
}

WORK="$(mktemp -d /tmp/moonflux-p15-bulk.XXXXXX)"
BROKER_PORT="${MOONFLUX_P15_BROKER_PORT:-19501}"
SC_PORT="${MOONFLUX_P15_SC_PORT:-19502}"
A_PORT="${MOONFLUX_P15_A_PORT:-19503}"
B_PORT="${MOONFLUX_P15_B_PORT:-19504}"
TOPIC="${MOONFLUX_P15_TOPIC:-bulk}"

# One segment per partition, so "the follower's copy" is one file to
# compare — this gate is about bytes on the wire, not about rolling
# (P8 covers rolling). The index keeps its default density: this gate
# is not about read amplification either, and a sparse index makes
# every read a full-segment scan by design (P8).
export MOONFLUX_ROLL_BYTES="${MOONFLUX_P15_ROLL_BYTES:-67108864}"
export MOONFLUX_INDEX_EVERY="${MOONFLUX_P15_INDEX_EVERY:-64}"
export MOONFLUX_RETAIN_BYTES=0
export MOONFLUX_RETAIN_MS=0

# 20 MiB of records (240k lines of 84 bytes): past the 8 MiB write cap
# that used to reset the connection, past the 8 MiB reply cap that used
# to drop the reader, and past the 4 MiB produce chunk in five of them.
BULK_MIB="${MOONFLUX_P15_MIB:-20}"
CLUSTER_MIB="${MOONFLUX_P15_CLUSTER_MIB:-12}"

BROKER_PID=""
SC_PID=""
A_PID=""
B_PID=""

cleanup() {
  for pid in "$BROKER_PID" "$SC_PID" "$A_PID" "$B_PID"; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
  done
  wait 2>/dev/null || true
}
trap 'cleanup; rm -rf "$WORK"' EXIT

fail() { echo "E2E-P15 FAIL: $*" >&2; exit 1; }
pass() { echo "E2E-P15 PASS: $*"; }

# Fixed ports: a leftover listener would make every assertion a
# statement about the wrong process.
for port in "$BROKER_PORT" "$SC_PORT" "$A_PORT" "$B_PORT"; do
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

# one generator for every payload: <value-bytes> lines, so the record
# count is a number this script can state exactly
gen_lines() { # $1 = path, $2 = lines, $3 = value bytes, $4 = char
  python3 - "$1" "$2" "$3" "$4" <<'PY'
import sys
path, lines, width, ch = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
row = ch * width
with open(path, "w") as fh:
    for i in range(lines):
        fh.write("%s\n" % row)
PY
}

BULK_LINES=$((BULK_MIB * 1024 * 1024 / 84))
gen_lines "$WORK/bulk.txt" "$BULK_LINES" 83 "b"
[ "$(wc -c < "$WORK/bulk.txt" | tr -d ' ')" -gt 8388608 ] ||
  fail "the test payload is smaller than the cap it exists to exceed"

# ---- 1. 20 MiB in, 20 MiB out, byte-identical ---------------------------
mkdir -p "$WORK/broker"
"$EXE" serve --data-dir "$WORK/broker" --listen "127.0.0.1:$BROKER_PORT" \
  > "$WORK/broker.log" 2>&1 &
BROKER_PID=$!
wait_listen "$BROKER_PORT" || { cat "$WORK/broker.log"; fail "serve did not start"; }

PRODUCED="$("$EXE" produce --topic "$TOPIC" --file "$WORK/bulk.txt" \
  --remote "127.0.0.1:$BROKER_PORT")" ||
  fail "the bulk produce failed: $PRODUCED"
printf '%s\n' "$PRODUCED" | grep -q "produced $BULK_LINES records" ||
  fail "the produce did not report every record: $PRODUCED"
# the chunked send reports one range: it must start at 0 and end at the
# record count, or the chunks did not stay contiguous
printf '%s\n' "$PRODUCED" | grep -q "offsets 0\.\.$BULK_LINES" ||
  fail "the produce range is not the whole send: $PRODUCED"

"$EXE" consume --topic "$TOPIC" --remote "127.0.0.1:$BROKER_PORT" \
  > "$WORK/remote.txt" || fail "the bulk consume failed"
"$EXE" consume --topic "$TOPIC" --data-dir "$WORK/broker" \
  > "$WORK/local.txt" || fail "the local consume failed"
[ "$(wc -l < "$WORK/remote.txt" | tr -d ' ')" = "$BULK_LINES" ] ||
  fail "the remote read returned $(wc -l < "$WORK/remote.txt") of $BULK_LINES records"
cmp "$WORK/remote.txt" "$WORK/local.txt" ||
  fail "the remote read differs from the local read"
pass "1: $BULK_MIB MiB produced and drained byte-identically ($BULK_LINES records, $(wc -c < "$WORK/remote.txt" | tr -d ' ') bytes)"

# ---- 2. offsets survive the chunk boundaries ----------------------------
MID=$((BULK_LINES / 3))
"$EXE" consume --topic "$TOPIC" --from "$MID" --remote "127.0.0.1:$BROKER_PORT" \
  > "$WORK/tail.txt" || fail "--from $MID failed"
tail -n +$((MID + 1)) "$WORK/local.txt" > "$WORK/want-tail.txt"
cmp "$WORK/tail.txt" "$WORK/want-tail.txt" ||
  fail "reading from $MID did not return the exact tail"
# and the first offset really is what was asked for, not a chunk start
[ "$(head -1 "$WORK/tail.txt" | cut -f1)" = "$MID" ] ||
  fail "the tail starts at offset $(head -1 "$WORK/tail.txt" | cut -f1), not $MID"
pass "2: --from $MID returns exactly the tail of the log, offsets intact"

# ---- 3. an oversize record is refused by name, and the broker lives -----
python3 - "$WORK/huge.txt" <<'PY'
import sys
with open(sys.argv[1], "w") as fh:
    fh.write("z" * (5 * 1024 * 1024))
    fh.write("\n")
PY
HUGE_ERR="$("$EXE" produce --topic "$TOPIC" --file "$WORK/huge.txt" \
  --remote "127.0.0.1:$BROKER_PORT" 2>&1)" && fail "an oversize record was accepted"
printf '%s\n' "$HUGE_ERR" | grep -q "per-field limit" ||
  fail "the oversize refusal did not name the limit: $HUGE_ERR"
printf 'one\ntwo\nthree\n' > "$WORK/small.txt"
"$EXE" produce --topic "$TOPIC" --file "$WORK/small.txt" \
  --remote "127.0.0.1:$BROKER_PORT" > /dev/null ||
  fail "the broker did not survive the oversize refusal"
"$EXE" consume --topic "$TOPIC" --from "$BULK_LINES" \
  --remote "127.0.0.1:$BROKER_PORT" > "$WORK/after.txt" ||
  fail "consume after the refusal failed"
[ "$(wc -l < "$WORK/after.txt" | tr -d ' ')" = "3" ] ||
  fail "the broker lost its footing after the refusal"
pass "3: a 5 MiB record is refused by name and the broker keeps serving"

# ---- 4. an over-budget frame is refused loudly, not silently ------------
# The CLI chunks, so nothing it sends can exceed the transport budget.
# This leg speaks raw MFS on purpose: a peer that ignores the budget
# must get a *reported* refusal, not the silent reset the old 8 MiB cap
# produced (which read as "connection reset by peer" at the client and
# as nothing at all in the server log).
python3 - "$BROKER_PORT" "$((18 * 1024 * 1024))" <<'PY'
import socket, struct, sys
port, total = int(sys.argv[1]), int(sys.argv[2])
s = socket.create_connection(("127.0.0.1", port))


def send(cmd, rid, payload=b""):
    s.sendall(b"MFS" + bytes([2, cmd]) + struct.pack(">II", rid, len(payload)) + payload)


def recv_frame():
    head = b""
    while len(head) < 13:
        got = s.recv(13 - len(head))
        if not got:
            raise SystemExit("eof in header")
        head += got
    cmd, rid, length = struct.unpack(">BII", head[4:13])
    body = b""
    while len(body) < length:
        got = s.recv(min(1 << 20, length - len(body)))
        if not got:
            raise SystemExit("eof in body")
        body += got
    return cmd, rid, body


send(1, 0, struct.pack(">II", 1, 0))
recv_frame()
# one produce whose *session* frame is over the transport budget: the
# header says so before the payload has to arrive, which is exactly
# what the server can refuse cheaply
payload_len = total
# the peer gives up on us part-way through, so "the socket refused"
# is the expected outcome, not a failure of this script
s.settimeout(30.0)
try:
    s.sendall(b"MFS" + bytes([2, 3]) + struct.pack(">II", 1, payload_len))
    block = b"x" * (1 << 20)
    for _ in range(payload_len // len(block)):
        s.sendall(block)
except (OSError, socket.timeout):
    pass
s.close()
PY
sleep 0.5
grep -q "bytes buffered with no complete request" "$WORK/broker.log" ||
  fail "the server did not report the over-budget frame: $(cat "$WORK/broker.log")"
"$EXE" consume --topic "$TOPIC" --from "$BULK_LINES" --remote "127.0.0.1:$BROKER_PORT" \
  > /dev/null || fail "the broker died with the over-budget frame"
pass "4: an over-budget frame is reported and the broker survives it"

kill "$BROKER_PID" 2>/dev/null || true
wait "$BROKER_PID" 2>/dev/null || true
BROKER_PID=""

# ---- 5. a big batch replicates -----------------------------------------
mkdir -p "$WORK/sc" "$WORK/spu-a" "$WORK/spu-b"
"$EXE" sc --listen "127.0.0.1:$SC_PORT" --data-dir "$WORK/sc" > "$WORK/sc.log" 2>&1 &
SC_PID=$!
wait_listen "$SC_PORT" || { cat "$WORK/sc.log"; fail "sc did not start"; }

for node in spu-a spu-b; do
  "$EXE" pipeline apply -f /dev/stdin --data-dir "$WORK/$node" <<EOF > /dev/null
{
  "apiVersion": "moonflux.io/v1alpha1",
  "kind": "Pipeline",
  "metadata": { "name": "bulk" },
  "spec": {
    "source": { "type": "file", "path": "$WORK/bulk.txt" },
    "transforms": [],
    "topic": { "name": "$TOPIC" },
    "sink": { "type": "stdout" }
  }
}
EOF
done

A_PID="$("$EXE" spu --id spu-a --listen "127.0.0.1:$A_PORT" --data-dir "$WORK/spu-a" \
  --sc "127.0.0.1:$SC_PORT" > "$WORK/spu-a.log" 2>&1 & echo $!)"
B_PID="$("$EXE" spu --id spu-b --listen "127.0.0.1:$B_PORT" --data-dir "$WORK/spu-b" \
  --sc "127.0.0.1:$SC_PORT" > "$WORK/spu-b.log" 2>&1 & echo $!)"
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

# 64 KiB records on purpose: the sync window is bounded by *records*
# (512) as well as bytes, and 512 x 64 KiB is past the 16 MiB byte
# budget — so a replica that ignored the byte cap would build a frame
# nothing could carry, while a replica that honours it catches up in
# more than one round. Small records would test neither.
CLUSTER_LINES=$((CLUSTER_MIB * 1024 * 1024 / 65536))
gen_lines "$WORK/cluster.txt" "$CLUSTER_LINES" 65535 "c"
"$EXE" produce --topic "$TOPIC" --file "$WORK/cluster.txt" --remote "$LEADER" > /dev/null ||
  fail "the cluster produce failed"

FOLLOWER="127.0.0.1:$A_PORT"
[ "$LEADER" = "127.0.0.1:$A_PORT" ] && FOLLOWER="127.0.0.1:$B_PORT"
FOLLOWER_NAME="spu-a"
[ "$FOLLOWER" = "127.0.0.1:$B_PORT" ] && FOLLOWER_NAME="spu-b"
LEADER_NAME="spu-a"
[ "$LEADER" = "127.0.0.1:$B_PORT" ] && LEADER_NAME="spu-b"

# the follower must reach the leader's end under a *bounded* window: a
# few rounds of SYNC_FETCH, each of which has to fit one frame
for _ in $(seq 1 120); do
  HW="$("$EXE" cluster offsets --topic "$TOPIC" --partition 0 --remote "$LEADER" 2>/dev/null |
    awk '{print $1}')"
  [ "$HW" = "$CLUSTER_LINES" ] && break
  sleep 0.25
done
[ "$HW" = "$CLUSTER_LINES" ] ||
  { tail -5 "$WORK/sc.log"; fail "replication stalled at hw=$HW of $CLUSTER_LINES"; }

LEADER_DIR="$WORK/$LEADER_NAME/topics/$TOPIC/partition-0"
FOLLOWER_DIR="$WORK/$FOLLOWER_NAME/topics/$TOPIC/partition-0"
diff -r "$LEADER_DIR" "$FOLLOWER_DIR" > /dev/null ||
  { diff -r "$LEADER_DIR" "$FOLLOWER_DIR" | head -5; fail "the follower's partition is not byte-identical"; }
pass "5: $CLUSTER_MIB MiB replicated byte-identically (hw=$HW, follower=$FOLLOWER_NAME, bounded sync window)"

echo "E2E-P15: all green"
