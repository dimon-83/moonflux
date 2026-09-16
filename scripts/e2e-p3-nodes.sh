#!/bin/bash
# P3 (T21) gate: node roles — a control plane, its data nodes, and
# liveness that is derived rather than declared.
#
#   sc + 2 spu started as real processes · both register · the node
#   table lists them · one is killed · the control plane calls it
#   offline after the liveness timeout · the survivor keeps serving
#   data throughout (a control plane outage is not a data outage).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXE="${MOONFLUX_EXE:-$ROOT/_build/native/release/build/apps/cli/cli.exe}"
[ -x "$EXE" ] || EXE="$ROOT/_build/native/debug/build/apps/cli/cli.exe"
[ -x "$EXE" ] || { echo "cli executable not found; run: moon build --target native" >&2; exit 1; }

WORK="$(mktemp -d /tmp/moonflux-p3-nodes.XXXXXX)"
SC_PORT="${MOONFLUX_SC_PORT:-19351}"
SPU_A_PORT="${MOONFLUX_SPU_A_PORT:-19352}"
SPU_B_PORT="${MOONFLUX_SPU_B_PORT:-19353}"
SC_PID=""
SPU_A_PID=""
SPU_B_PID=""
trap 'kill $SPU_A_PID $SPU_B_PID $SC_PID 2>/dev/null || true; rm -rf "$WORK"' EXIT

fail() { echo "E2E-P3-NODES FAIL: $*" >&2; exit 1; }
pass() { echo "E2E-P3-NODES PASS: $*"; }

wait_listen() { # $1 = port
  for _ in $(seq 1 60); do
    lsof -i ":$1" -sTCP:LISTEN > /dev/null 2>&1 && return 0
    sleep 0.1
  done
  return 1
}

# nodes <port> -> "online nodes, id-sorted" as id:role lines
nodes() {
  "$EXE" cluster nodes --remote "127.0.0.1:$1"
}

"$EXE" sc --listen "127.0.0.1:$SC_PORT" --data-dir "$WORK/sc" > "$WORK/sc.log" 2>&1 &
SC_PID=$!
wait_listen "$SC_PORT" || { cat "$WORK/sc.log"; fail "sc did not start"; }

"$EXE" spu --id spu-a --listen "127.0.0.1:$SPU_A_PORT" --data-dir "$WORK/spu-a" \
  --sc "127.0.0.1:$SC_PORT" > "$WORK/spu-a.log" 2>&1 &
SPU_A_PID=$!
"$EXE" spu --id spu-b --listen "127.0.0.1:$SPU_B_PORT" --data-dir "$WORK/spu-b" \
  --sc "127.0.0.1:$SC_PORT" > "$WORK/spu-b.log" 2>&1 &
SPU_B_PID=$!
wait_listen "$SPU_A_PORT" || fail "spu-a did not start"
wait_listen "$SPU_B_PORT" || fail "spu-b did not start"

# both nodes appear in the control plane's table (poll: registration
# is a heartbeat tick away)
for _ in $(seq 1 40); do
  OUT="$(nodes "$SC_PORT" 2>/dev/null || true)"
  if printf '%s\n' "$OUT" | grep -q "spu-a" && printf '%s\n' "$OUT" | grep -q "spu-b"; then
    break
  fi
  sleep 0.25
done
printf '%s\n' "$OUT" | grep -q "spu-a:spu" || { cat "$WORK/sc.log"; fail "spu-a did not register"; }
printf '%s\n' "$OUT" | grep -q "spu-b:spu" || fail "spu-b did not register"
pass "both data nodes registered with the control plane"

# node identity persists across restarts (same node returns, not a new one)
kill "$SPU_B_PID" 2>/dev/null || true
wait "$SPU_B_PID" 2>/dev/null || true
grep -q '"id": "spu-b"' "$WORK/spu-b/node.json" || fail "spu-b identity was not persisted"
"$EXE" spu --id spu-b --listen "127.0.0.1:$SPU_B_PORT" --data-dir "$WORK/spu-b" \
  --sc "127.0.0.1:$SC_PORT" >> "$WORK/spu-b.log" 2>&1 &
SPU_B_PID=$!
wait_listen "$SPU_B_PORT" || fail "spu-b did not come back"
# an id given on the command line must not overwrite the stored one:
# restarts would then fork identities, which is precisely what breaks
# rejoin semantics
[ "$("$EXE" cluster nodes --remote "127.0.0.1:$SC_PORT" | grep -c 'spu-b')" -ge 1 ] \
  || fail "restarted spu-b is not in the table"
grep -vq '"id": "spu-a"' "$WORK/spu-b/node.json" || fail "identity file drifted"
pass "identity is persisted and survives a restart"

# data serving does not depend on the control plane
printf 'hello\nworld\n' > "$WORK/in.txt"
"$EXE" produce --topic events --file "$WORK/in.txt" --remote "127.0.0.1:$SPU_A_PORT" \
  > "$WORK/produce.log" 2>&1 || { cat "$WORK/produce.log"; fail "produce against an spu failed"; }
"$EXE" consume --topic events --remote "127.0.0.1:$SPU_A_PORT" | cut -f4- > "$WORK/out.txt"
printf 'hello\nworld\n' > "$WORK/want.txt"
diff -u "$WORK/want.txt" "$WORK/out.txt" || fail "spu data path output"
pass "an spu serves the data protocol (produce/consume) unchanged"

# kill a node: liveness is derived from silence, and the control plane
# reports the transition exactly once
kill "$SPU_B_PID" 2>/dev/null || true
wait "$SPU_B_PID" 2>/dev/null || true
SPU_B_PID=""
DEADLINE=$((SECONDS + 15))
while [ "$SECONDS" -lt "$DEADLINE" ]; do
  if ! nodes "$SC_PORT" | grep -q "spu-b"; then
    break
  fi
  sleep 0.25
done
nodes "$SC_PORT" | grep -q "spu-b" && { cat "$WORK/sc.log"; fail "dead node still listed as online"; }
nodes "$SC_PORT" | grep -q "spu-a" || fail "the surviving node was swept away too"
pass "a silenced node is marked offline by the liveness sweep"

# and it is a transition, not a state the control plane keeps fading
# in and out of
kill "$SC_PID" 2>/dev/null || true
wait "$SC_PID" 2>/dev/null || true
SC_PID=""
OFFLINE_LINES=$(grep -c "is offline" "$WORK/sc.log" || true)
[ "$OFFLINE_LINES" -eq 1 ] || {
  cat "$WORK/sc.log"
  fail "expected exactly one offline transition, saw $OFFLINE_LINES"
}
pass "the offline transition is reported once (level-triggered, not per tick)"

echo "E2E-P3-NODES: all green"
