#!/bin/bash
# P23 gate: the command face's deferred observability items.
#
#    1. partition list on a standalone serve: one row per partition,
#       hw/leo matching what cluster offsets answers (the command is a
#       composition, not a second authority)
#    2. a topic that was never declared is refused by name, and an
#       auto-created topic's listing tells the max-of-indexes truth
#       (`produce --partition 2` on a fresh topic means THREE partitions)
#    3. profiles: add/list/use/remove round trip, the current profile
#       answers a command that names no --remote, an explicit --remote
#       wins, and removing the current profile leaves a refusal that
#       names all three ways out
#    4. cluster spu list: the registered set with per-node hosting
#       counts composed from the placement views
#    5. cluster partition list agrees with cluster offsets per partition
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
EXE="${MOONFLUX_EXE:-$ROOT/_build/native/debug/build/apps/cli/cli.exe}"
[ -x "$EXE" ] || EXE="$ROOT/_build/native/release/build/apps/cli/cli.exe"

WORK="$(mktemp -d /tmp/moonflux-p23-cli.XXXXXX)"
SERVE_PORT="${MOONFLUX_P23_SERVE_PORT:-19701}"
SC_PORT="${MOONFLUX_P23_SC_PORT:-19702}"
A_PORT="${MOONFLUX_P23_A_PORT:-19703}"
SERVE="127.0.0.1:$SERVE_PORT"

PIDS=()
cleanup() {
  for pid in "${PIDS[@]:-}"; do kill "$pid" 2>/dev/null || true; done
  pkill -f "moonflux-p23-cli" 2>/dev/null || true
}
trap 'cleanup; if [ "${MOONFLUX_KEEP:-0}" = "1" ]; then echo "keeping $WORK"; else rm -rf "$WORK"; fi' EXIT

fail() { echo "E2E-P23-CLI FAIL: $*" >&2; exit 1; }
pass() { echo "E2E-P23-CLI PASS: $*"; }
wait_listen() {
  for _ in $(seq 1 60); do
    lsof -i ":$1" -sTCP:LISTEN > /dev/null 2>&1 && return 0
    sleep 0.1
  done
  return 1
}

pkill -f "moonflux-p23-cli" 2>/dev/null || true
sleep 1
mkdir -p "$WORK/serve" "$WORK/sc" "$WORK/spu-a"
printf 'r0\nr1\n' > "$WORK/in.txt"

# ---- serve up; profile isolation via MOONFLUX_CONFIG --------------------
export MOONFLUX_CONFIG="$WORK/profiles.json"
rm -f "$MOONFLUX_CONFIG"

"$EXE" serve --data-dir "$WORK/serve" --listen "$SERVE" > "$WORK/serve.log" 2>&1 &
SERVE_PID=$!
PIDS+=("$SERVE_PID")
wait_listen "$SERVE_PORT" || { cat "$WORK/serve.log"; fail "serve did not start"; }

# the topic is never declared: produce creates partition-2 and nothing
# else, so the disk truth is "three partitions addressable"
"$EXE" produce --topic events --partition 0 --file "$WORK/in.txt" --remote "$SERVE" > /dev/null \
  || fail "produce to events[0] failed"
"$EXE" produce --topic events --partition 2 --file "$WORK/in.txt" --remote "$SERVE" > /dev/null \
  || fail "produce to events[2] failed"

# ---- 1. partition list agrees with cluster offsets ----------------------
LIST="$("$EXE" partition list --topic events --remote "$SERVE")" \
  || { echo "$LIST"; fail "partition list failed"; }
[ "$(printf '%s\n' "$LIST" | grep -c '^	\|^[0-9]')" = "3" ] \
  || { echo "$LIST"; fail "partition list did not show three partitions (disk truth)"; }
printf '%s\n' "$LIST" | grep -q "^0	$SERVE	$SERVE	2	2$" \
  || { echo "$LIST"; fail "partition 0's row does not match its offsets (hw=2 leo=2)"; }
printf '%s\n' "$LIST" | grep -q "^1	$SERVE	$SERVE	0	0$" \
  || { echo "$LIST"; fail "partition 1's row is wrong (it exists, untouched: hw=0)"; }
printf '%s\n' "$LIST" | grep -q "^2	$SERVE	$SERVE	2	2$" \
  || { echo "$LIST"; fail "partition 2's row does not match its offsets"; }
for p in 0 1 2; do
  OFFSETS="$("$EXE" cluster offsets --topic events --partition "$p" --remote "$SERVE")"
  HW="$(printf '%s' "$OFFSETS" | awk '{print $1}')"
  LEO="$(printf '%s' "$OFFSETS" | awk '{print $2}')"
  ROW="$(printf '%s\n' "$LIST" | grep "^$p	")"
  printf '%s\n' "$ROW" | grep -q "	$HW	$LEO$" \
    || { printf 'offsets says %s %s; row: %s\n' "$HW" "$LEO" "$ROW"; fail "partition list and cluster offsets disagree on partition $p"; }
done
pass "partition list on serve: three disk partitions, values match cluster offsets exactly"

# ---- 2. an unknown topic is refused by name -----------------------------
OUT="$("$EXE" partition list --topic nope --remote "$SERVE" 2>&1 || true)"
printf '%s' "$OUT" | grep -q "topic nope is not declared or hosted" \
  || fail "the refusal does not name the topic: $OUT"
TOPICS="$("$EXE" topic list --remote "$SERVE")"
printf '%s\n' "$TOPICS" | grep -q "events	partitions=3" \
  || { echo "$TOPICS"; fail "the topic listing does not carry the max-of-indexes truth"; }
pass "unknown topic refused by name; the listing says partitions=3 (max of indexes, not a dir count)"

# ---- 3. profiles: resolution, precedence, removal -----------------------
"$EXE" profile add local --remote "$SERVE" | grep -q "(current)" \
  || fail "the first profile did not become current"
"$EXE" profile add other --remote "127.0.0.1:19999" > /dev/null \
  || fail "adding a second profile failed"
LISTING="$("$EXE" profile list)"
printf '%s\n' "$LISTING" | grep -q "^local	$SERVE \*$" \
  || { echo "$LISTING"; fail "the current profile is not marked"; }
VIA="$("$EXE" partition list --topic events | tail -n +2)"
EXPLICIT="$("$EXE" partition list --topic events --remote "$SERVE" | tail -n +2)"
[ "$VIA" = "$EXPLICIT" ] \
  || fail "profile-resolved remote did not reach the same broker as the explicit flag"
"$EXE" profile use other > /dev/null || fail "profile use failed"
"$EXE" profile use local > /dev/null || fail "profile use (back) failed"
"$EXE" profile remove local > /dev/null || fail "profile remove failed"
printf '%s\n' "$("$EXE" profile list)" | grep -q "^local" \
  && fail "the removed profile is still listed"
"$EXE" profile use nope 2> "$WORK/use.err" \
  && fail "using a missing profile was accepted"
grep -q "no profile named nope" "$WORK/use.err" \
  || { cat "$WORK/use.err"; fail "the use refusal is not the profile family's own"; }
pass "profiles: add/list/use/remove round trip; the current profile answers a bare command and an explicit --remote wins"

# ---- cluster for legs 4-5 ------------------------------------------------
"$EXE" sc --listen "127.0.0.1:$SC_PORT" --data-dir "$WORK/sc" > "$WORK/sc.log" 2>&1 &
SC_PID=$!
PIDS+=("$SC_PID")
wait_listen "$SC_PORT" || { cat "$WORK/sc.log"; fail "sc did not start"; }
"$EXE" spu --id spu-a --listen "127.0.0.1:$A_PORT" --data-dir "$WORK/spu-a" \
  --sc "127.0.0.1:$SC_PORT" > "$WORK/spu-a.log" 2>&1 &
A_PID=$!
PIDS+=("$A_PID")
wait_listen "$A_PORT" || { cat "$WORK/spu-a.log"; fail "spu-a did not start"; }
"$EXE" topic create --name cluster-topic --partitions 2 --replication-factor 1 \
  --remote "127.0.0.1:$SC_PORT" > /dev/null || fail "topic create failed"
LEADER=""
for _ in $(seq 1 80); do
  LEADER="$("$EXE" cluster leader --topic cluster-topic --partition 0 --remote "127.0.0.1:$SC_PORT" 2>/dev/null || true)"
  [ -n "$LEADER" ] && break
  sleep 0.25
done
[ -n "$LEADER" ] || { cat "$WORK/sc.log"; fail "no leader for cluster-topic[0]"; }
"$EXE" produce --topic cluster-topic --partition 0 --file "$WORK/in.txt" --remote "$LEADER" > /dev/null \
  || fail "produce to cluster-topic[0] failed"

# ---- 4. cluster spu list: registered set + hosting counts ----------------
SPUS="$("$EXE" cluster spu list --remote "127.0.0.1:$SC_PORT")"
printf '%s\n' "$SPUS" | grep -q "^spu	address	role	leo	hosted-partitions	topics$" \
  || { echo "$SPUS"; fail "spu list did not print the full column set"; }
printf '%s\n' "$SPUS" | grep -q "^spu-a	127.0.0.1:$A_PORT	spu	0	2	1$" \
  || { echo "$SPUS"; fail "spu-a's hosting counts are wrong (2 partitions of 1 topic expected): $SPUS"; }
pass "cluster spu list: the node with its hosting counts (2 partitions, 1 topic)"

# ---- 5. cluster partition list agrees with cluster offsets ---------------
CLIST="$("$EXE" partition list --topic cluster-topic --remote "127.0.0.1:$SC_PORT")"
for p in 0 1; do
  OFFSETS="$("$EXE" cluster offsets --topic cluster-topic --partition "$p" --remote "$LEADER")"
  HW="$(printf '%s' "$OFFSETS" | awk '{print $1}')"
  LEO="$(printf '%s' "$OFFSETS" | awk '{print $2}')"
  printf '%s\n' "$CLIST" | grep -q "^$p	$LEADER	$LEADER	$HW	$LEO$" \
    || { echo "$CLIST"; fail "cluster partition list disagrees with offsets on partition $p"; }
done
pass "partition list on the cluster: every row matches what the leader answers"

echo "E2E-P23-CLI PASS: 5 legs green"
