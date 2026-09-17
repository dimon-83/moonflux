#!/bin/bash
# P3 (T24) gate: metadata — declared topics drive placement, and the
# declaration survives a control-plane restart.
#
#   1. `topic create` declares a topic; the control plane persists it
#      and refuses a duplicate by name
#   2. the declaration becomes placement on the next reconcile (no
#      restart, no extra command): `cluster status` shows the leader
#   3. a control-plane restart keeps both the declarations and the
#      placement it derived — a restart is not a rebalance
#   4. `topic delete` undeclares; the partitions go away on the next
#      reconcile, and the removal is reported
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# The debug build is what `moon build --target native` (and `moon test`)
# produce, so it is the artifact every gate here means to test. A release
# binary is only a fallback: preferring it once meant a gate silently
# tested a build from an earlier session.
EXE="${MOONFLUX_EXE:-$ROOT/_build/native/debug/build/apps/cli/cli.exe}"
[ -x "$EXE" ] || EXE="$ROOT/_build/native/release/build/apps/cli/cli.exe"
[ -x "$EXE" ] || { echo "cli executable not found; run: moon build --target native" >&2; exit 1; }

WORK="$(mktemp -d /tmp/moonflux-p3-meta.XXXXXX)"
SC_PORT="${MOONFLUX_SC_PORT:-19381}"
A_PORT="${MOONFLUX_SPU_A_PORT:-19382}"
TOPIC="${MOONFLUX_P3_TOPIC:-orders}"

SC_PID=""; A_PID=""
cleanup() {
  for pid in "$A_PID" "$SC_PID"; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
    [ -n "$pid" ] && wait "$pid" 2>/dev/null || true
  done
}
trap 'cleanup; rm -rf "$WORK"' EXIT

fail() { echo "E2E-P3-META FAIL: $*" >&2; exit 1; }
pass() { echo "E2E-P3-META PASS: $*"; }

wait_listen() {
  for _ in $(seq 1 60); do
    lsof -i ":$1" -sTCP:LISTEN > /dev/null 2>&1 && return 0
    sleep 0.1
  done
  return 1
}

status() { "$EXE" cluster status --remote "127.0.0.1:$SC_PORT" 2>&1; }

mkdir -p "$WORK/sc" "$WORK/spu-a"
"$EXE" pipeline apply -f /dev/stdin --data-dir "$WORK/spu-a" <<EOF > /dev/null
{
  "apiVersion": "moonflux.io/v1alpha1",
  "kind": "Pipeline",
  "metadata": { "name": "orders" },
  "spec": {
    "source": { "type": "file", "path": "$WORK/in.txt" },
    "transforms": [],
    "topic": { "name": "$TOPIC" },
    "sink": { "type": "stdout" }
  }
}
EOF

"$EXE" sc --listen "127.0.0.1:$SC_PORT" --data-dir "$WORK/sc" > "$WORK/sc.log" 2>&1 &
SC_PID=$!
wait_listen "$SC_PORT" || { cat "$WORK/sc.log"; fail "sc did not start"; }

# ---- 1. declare a topic -------------------------------------------------
"$EXE" topic create --name "$TOPIC" --partitions 1 --replication-factor 1 \
  --remote "127.0.0.1:$SC_PORT" > "$WORK/create.log" 2>&1 \
  || { cat "$WORK/create.log"; fail "topic create failed"; }
grep -q "declared topic $TOPIC" "$WORK/create.log" || fail "create did not report the declaration"
[ -f "$WORK/sc/metadata.json" ] || fail "the declaration was not persisted"
grep -q '"version": 1' "$WORK/sc/metadata.json" || fail "metadata version was not recorded"
pass "topic create persisted a declaration (metadata.json version 1)"

if "$EXE" topic create --name "$TOPIC" --remote "127.0.0.1:$SC_PORT" > "$WORK/dup.log" 2>&1; then
  fail "a duplicate topic must be refused"
fi
grep -q "already exists" "$WORK/dup.log" || { cat "$WORK/dup.log"; fail "duplicate refusal lacks the reason"; }
pass "a duplicate topic name is refused"

if "$EXE" topic create --name "Bad Name" --remote "127.0.0.1:$SC_PORT" > "$WORK/bad.log" 2>&1; then
  fail "an invalid topic name must be refused"
fi
grep -q "invalid topic name" "$WORK/bad.log" || { cat "$WORK/bad.log"; fail "name validation is missing"; }
pass "the topic name whitelist (core/spec's) is enforced at the control plane"

"$EXE" topic list --remote "127.0.0.1:$SC_PORT" | grep -q "^$TOPIC" \
  || { "$EXE" topic list --remote "127.0.0.1:$SC_PORT"; fail "topic list does not show the declaration"; }
pass "topic list reads back the declaration"

# ---- 2. the declaration becomes placement ------------------------------
A_PID="$("$EXE" spu --id spu-a --listen "127.0.0.1:$A_PORT" --data-dir "$WORK/spu-a" \
  --sc "127.0.0.1:$SC_PORT" > "$WORK/spu-a.log" 2>&1 & echo $!)"
wait_listen "$A_PORT" || fail "spu-a did not start"

LEADER=""
for _ in $(seq 1 80); do
  LEADER="$(status | grep -o 'leader=127.0.0.1:[0-9]*' | head -1 || true)"
  [ -n "$LEADER" ] && break
  sleep 0.25
done
[ -n "$LEADER" ] || { status; cat "$WORK/sc.log"; fail "the declaration never became placement"; }
grep -q "placed $TOPIC\[0\]" "$WORK/sc.log" || { cat "$WORK/sc.log"; fail "placement was not reported"; }
pass "the declared topic was placed and given a leader ($LEADER) without further commands"

# ---- 3. a restart keeps declarations and placement ---------------------
PLACEMENT_BEFORE=$(cat "$WORK/sc/cluster-state.json")
kill "$SC_PID" 2>/dev/null || true
wait "$SC_PID" 2>/dev/null || true
SC_PID=""
"$EXE" sc --listen "127.0.0.1:$SC_PORT" --data-dir "$WORK/sc" >> "$WORK/sc.log" 2>&1 &
SC_PID=$!
wait_listen "$SC_PORT" || fail "sc did not restart"

"$EXE" topic list --remote "127.0.0.1:$SC_PORT" | grep -q "^$TOPIC" \
  || fail "the declaration did not survive the restart"
# the placement must be the *same* one, not a freshly derived one: a
# restart is not an excuse to move partitions
for _ in $(seq 1 40); do
  [ "$(cat "$WORK/sc/cluster-state.json")" = "$PLACEMENT_BEFORE" ] && break
  sleep 0.25
done
[ "$(cat "$WORK/sc/cluster-state.json")" = "$PLACEMENT_BEFORE" ] \
  || { diff <(echo "$PLACEMENT_BEFORE") "$WORK/sc/cluster-state.json"; fail "the restart moved or rewrote placement"; }
# liveness is rediscovered from heartbeats, so the leader is reported
# again one heartbeat after the control plane comes back — the same
# rule that keeps a stale leader from being reported as live
LEADER_AFTER=""
for _ in $(seq 1 40); do
  LEADER_AFTER="$(status | grep -o 'leader=127.0.0.1:[0-9]*' | head -1 || true)"
  [ -n "$LEADER_AFTER" ] && break
  sleep 0.25
done
[ "$LEADER_AFTER" = "$LEADER" ] \
  || { status; fail "the leader changed across a control-plane restart ($LEADER -> $LEADER_AFTER)"; }
pass "declarations and placement survived a control-plane restart unchanged"

# ---- 4. undeclaring removes the partitions -----------------------------
"$EXE" topic delete --name "$TOPIC" --remote "127.0.0.1:$SC_PORT" > /dev/null \
  || fail "topic delete failed"
for _ in $(seq 1 40); do
  grep -q "removed $TOPIC\[0\]" "$WORK/sc.log" && break
  sleep 0.25
done
grep -q "removed $TOPIC\[0\]" "$WORK/sc.log" \
  || { cat "$WORK/sc.log"; fail "the removal was not reconciled"; }
"$EXE" topic list --remote "127.0.0.1:$SC_PORT" | grep -q "^$TOPIC" \
  && fail "the deleted topic is still declared"
pass "topic delete removed the partitions on the next reconcile (absence is the instruction)"

echo "E2E-P3-META: all green"
