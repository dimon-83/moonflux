#!/bin/bash
# P4 (T27) gate: read modes — a consumer can choose the replicated
# prefix (Committed) or everything the leader holds (Uncommitted), and
# the difference is observable exactly when a replica is gone.
#
#   1. with both replicas live, the two modes agree (nothing is
#      withheld while the cluster is healthy)
#   2. kill the follower, write more: Uncommitted sees the tail,
#      Committed stops at the watermark and says so on stderr
#   3. a committed read past the watermark is refused, not answered
#      with an empty window ("not replicated yet" is not "no data")
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXE="${MOONFLUX_EXE:-$ROOT/_build/native/release/build/apps/cli/cli.exe}"
[ -x "$EXE" ] || EXE="$ROOT/_build/native/debug/build/apps/cli/cli.exe"
[ -x "$EXE" ] || { echo "cli executable not found; run: moon build --target native" >&2; exit 1; }

WORK="$(mktemp -d /tmp/moonflux-p4-readmodes.XXXXXX)"
SC_PORT="${MOONFLUX_SC_PORT:-19391}"
A_PORT="${MOONFLUX_SPU_A_PORT:-19392}"
B_PORT="${MOONFLUX_SPU_B_PORT:-19393}"
TOPIC="${MOONFLUX_P4_TOPIC:-readings}"

SC_PID=""; A_PID=""; B_PID=""
cleanup() {
  for pid in "$A_PID" "$B_PID" "$SC_PID"; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
    [ -n "$pid" ] && wait "$pid" 2>/dev/null || true
  done
}
trap 'cleanup; rm -rf "$WORK"' EXIT

fail() { echo "E2E-P4-READMODES FAIL: $*" >&2; exit 1; }
pass() { echo "E2E-P4-READMODES PASS: $*"; }

wait_listen() {
  for _ in $(seq 1 60); do
    lsof -i ":$1" -sTCP:LISTEN > /dev/null 2>&1 && return 0
    sleep 0.1
  done
  return 1
}

leader_of() { "$EXE" cluster leader --topic "$TOPIC" --remote "127.0.0.1:$SC_PORT" 2>/dev/null || true; }
offsets() { "$EXE" cluster offsets --topic "$TOPIC" --remote "$1" 2>/dev/null || echo "?"; }

mkdir -p "$WORK/sc" "$WORK/spu-a" "$WORK/spu-b"
printf 'a1\na2\n' > "$WORK/in.txt"
for node in spu-a spu-b; do
  "$EXE" pipeline apply -f /dev/stdin --data-dir "$WORK/$node" <<EOF > /dev/null
{
  "apiVersion": "moonflux.io/v1alpha1",
  "kind": "Pipeline",
  "metadata": { "name": "readings" },
  "spec": {
    "source": { "type": "file", "path": "$WORK/in.txt" },
    "transforms": [],
    "topic": { "name": "$TOPIC" },
    "sink": { "type": "stdout" }
  }
}
EOF
done

"$EXE" sc --listen "127.0.0.1:$SC_PORT" --data-dir "$WORK/sc" > "$WORK/sc.log" 2>&1 &
SC_PID=$!
wait_listen "$SC_PORT" || { cat "$WORK/sc.log"; fail "sc did not start"; }
"$EXE" topic create --name "$TOPIC" --partitions 1 --replication-factor 2 \
  --remote "127.0.0.1:$SC_PORT" > /dev/null || fail "topic create failed"
A_PID="$("$EXE" spu --id spu-a --listen "127.0.0.1:$A_PORT" --data-dir "$WORK/spu-a" \
  --sc "127.0.0.1:$SC_PORT" > "$WORK/spu-a.log" 2>&1 & echo $!)"
B_PID="$("$EXE" spu --id spu-b --listen "127.0.0.1:$B_PORT" --data-dir "$WORK/spu-b" \
  --sc "127.0.0.1:$SC_PORT" > "$WORK/spu-b.log" 2>&1 & echo $!)"
wait_listen "$A_PORT" || fail "spu-a did not start"
wait_listen "$B_PORT" || fail "spu-b did not start"

LEADER=""
for _ in $(seq 1 80); do
  LEADER="$(leader_of)"
  [ -n "$LEADER" ] && break
  sleep 0.25
done
[ -n "$LEADER" ] || { cat "$WORK/sc.log"; fail "no leader was assigned"; }

"$EXE" produce --topic "$TOPIC" --file "$WORK/in.txt" --remote "$LEADER" > /dev/null \
  || fail "produce failed"
for _ in $(seq 1 60); do
  read -r HW LEO <<< "$(offsets "$LEADER")"
  [ "$HW" = "2" ] && break
  sleep 0.25
done
[ "$HW" = "2" ] || fail "the replicas did not settle (hw=$HW leo=$LEO)"

# ---- 1. healthy cluster: both modes agree ------------------------------
"$EXE" consume --topic "$TOPIC" --remote "$LEADER" | cut -f4- > "$WORK/uncommitted.txt"
"$EXE" consume --topic "$TOPIC" --remote "$LEADER" --committed 2> "$WORK/committed.err" \
  | cut -f4- > "$WORK/committed.txt"
diff -u "$WORK/uncommitted.txt" "$WORK/committed.txt" \
  || fail "the two read modes disagree while the cluster is healthy"
grep -q "hw=2 leo=2" "$WORK/committed.err" \
  || { cat "$WORK/committed.err"; fail "the committed read did not report its watermarks"; }
pass "healthy cluster: both modes return the same 2 records (hw=2 leo=2)"

# ---- 2. a replica dies: the modes diverge ------------------------------
if [ "$LEADER" = "127.0.0.1:$A_PORT" ]; then
  kill "$B_PID" 2>/dev/null || true; wait "$B_PID" 2>/dev/null || true; B_PID=""
else
  kill "$A_PID" 2>/dev/null || true; wait "$A_PID" 2>/dev/null || true; A_PID=""
fi
sleep 1
printf 'b3\nb4\n' > "$WORK/tail.txt"
"$EXE" produce --topic "$TOPIC" --file "$WORK/tail.txt" --remote "$LEADER" > /dev/null \
  || fail "produce with the replica down failed"
read -r HW LEO <<< "$(offsets "$LEADER")"
[ "$HW" = "2" ] || fail "the watermark should still be 2 (hw=$HW)"
[ "$LEO" = "4" ] || fail "the leader should hold 4 records (leo=$LEO)"

"$EXE" consume --topic "$TOPIC" --remote "$LEADER" | cut -f4- > "$WORK/uncommitted2.txt"
printf 'a1\na2\nb3\nb4\n' > "$WORK/want-uncommitted.txt"
diff -u "$WORK/want-uncommitted.txt" "$WORK/uncommitted2.txt" \
  || { cat "$WORK/uncommitted2.txt"; fail "the uncommitted read did not see the leader's tail"; }

"$EXE" consume --topic "$TOPIC" --remote "$LEADER" --committed 2> "$WORK/committed2.err" \
  | cut -f4- > "$WORK/committed2.txt"
printf 'a1\na2\n' > "$WORK/want-committed.txt"
diff -u "$WORK/want-committed.txt" "$WORK/committed2.txt" \
  || { cat "$WORK/committed2.txt"; fail "the committed read leaked the unreplicated tail"; }
grep -q "hw=2 leo=4" "$WORK/committed2.err" \
  || { cat "$WORK/committed2.err"; fail "the committed read reported the wrong watermarks"; }
pass "with a replica down: Uncommitted reads 4, Committed withholds the tail and reports hw=2 leo=4"

# ---- 3. reading past the watermark is refused --------------------------
# a consumer that has already read the committed prefix catches up by
# asking from offset 2: legal and empty (not an error). Asking from 3
# is beyond the watermark and must be a structured refusal.
"$EXE" consume --topic "$TOPIC" --from 2 --remote "$LEADER" --committed \
  > "$WORK/at-watermark.txt" 2> "$WORK/at-watermark.err" \
  || { cat "$WORK/at-watermark.err"; fail "reading exactly at the watermark must be legal"; }
[ -s "$WORK/at-watermark.txt" ] && fail "reading at the watermark should return nothing"

if "$EXE" consume --topic "$TOPIC" --from 3 --remote "$LEADER" --committed \
  > "$WORK/past.txt" 2> "$WORK/past.err"; then
  fail "reading past the watermark must be refused"
fi
grep -q "exceeds" "$WORK/past.err" \
  || { cat "$WORK/past.err"; fail "the refusal does not say why"; }
pass "a committed read at the watermark is empty-and-legal; one past it is refused with a reason"

echo "E2E-P4-READMODES: all green"
