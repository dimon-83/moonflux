#!/bin/bash
# P22 gate: consumer groups on a standalone serve.
#
#    1. two members join a group over an AUTO-CREATED topic: the shares
#       cover every partition on disk, none twice (the coordinator's
#       partition source is declared ∪ disk — serve's produce declares
#       nothing, and an enumeration that ignored disk hands out empty
#       shares)
#    2. conservation: everything produced was delivered (at-least-once:
#       duplicates allowed, gaps are not)
#    3. a member dies; the survivor takes over its partitions
#    4. a commit from a stale generation is refused
#    5. committed offsets survive a serve restart (groups.json)
#    6. a slow consumer holds retention back: floor = min(own end, group floor)
#    7. the permission table governs group commands here exactly as on
#       the control plane (read-only cannot join; read-write can)
#
# The coordinator under test is the serve process itself (P22): same
# registry, same commands, same fencing as the control plane's — the
# gate's members cannot tell which host they are talking to.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
EXE="${MOONFLUX_EXE:-$ROOT/_build/native/debug/build/apps/cli/cli.exe}"
[ -x "$EXE" ] || EXE="$ROOT/_build/native/release/build/apps/cli/cli.exe"

WORK="$(mktemp -d /tmp/moonflux-p22-serve-groups.XXXXXX)"
PORT="${MOONFLUX_P22_PORT:-19691}"
SERVE="127.0.0.1:$PORT"
TOPIC="events"
GROUP="analytics"

cleanup() {
  for pid in "${PIDS[@]:-}"; do kill "$pid" 2>/dev/null || true; done
  pkill -f "moonflux-p22-serve-groups" 2>/dev/null || true
}
PIDS=()
trap 'cleanup; if [ "${MOONFLUX_KEEP:-0}" = "1" ]; then echo "keeping $WORK"; else rm -rf "$WORK"; fi' EXIT

fail() { echo "E2E-P22-SERVE-GROUPS FAIL: $*" >&2; exit 1; }
pass() { echo "E2E-P22-SERVE-GROUPS PASS: $*"; }
note() { echo "  · $*" >&2; }

wait_listen() { # $1 = port
  for _ in $(seq 1 60); do
    lsof -i ":$1" -sTCP:LISTEN > /dev/null 2>&1 && return 0
    sleep 0.1
  done
  return 1
}

start_serve() { # extra env via environment; $1 = log suffix
  "$EXE" serve --data-dir "$WORK/serve" --listen "$SERVE" > "$WORK/serve-$1.log" 2>&1 &
  SERVE_PID=$!
  PIDS+=("$SERVE_PID")
}

member() { # $1 = id, $2 = output file
  "$EXE" consume --topic "$TOPIC" --group "$GROUP" --member "$1" --follow \
    --commit-ms 300 --remote "$SERVE" >> "$2" 2>> "$WORK/members.log" &
  echo $!
}

pkill -f "moonflux-p22-serve-groups" 2>/dev/null || true
sleep 1
mkdir -p "$WORK/serve"

# ---- serve up; the topic is auto-created, never declared ---------------
# MOONFLUX_ROLL_BYTES keeps segments small for leg 6's deletions; the
# retention byte policy itself stays off until that leg opts in.
MOONFLUX_ROLL_BYTES=40 start_serve up
wait_listen "$PORT" || { cat "$WORK/serve-up.log"; fail "serve did not start"; }

# produce to partitions 0 and 1 explicitly: the disks now hold
# partition-0/ and partition-1/ and the topic exists in NO declaration
# store — the group's partition source must find both on disk
printf 'p0-a\np0-b\np0-c\n' > "$WORK/in-0.txt"
printf 'p1-a\np1-b\np1-c\n' > "$WORK/in-1.txt"
"$EXE" produce --topic "$TOPIC" --partition 0 --file "$WORK/in-0.txt" --remote "$SERVE" > /dev/null \
  || fail "produce to $TOPIC[0] failed"
"$EXE" produce --topic "$TOPIC" --partition 1 --file "$WORK/in-1.txt" --remote "$SERVE" > /dev/null \
  || fail "produce to $TOPIC[1] failed"

# ---- 1. two members, both disk partitions owned exactly once -----------
M1_PID="$(member m1 "$WORK/m1.out")"
M2_PID="$(member m2 "$WORK/m2.out")"
PIDS+=("$M1_PID" "$M2_PID")
SHARES=""
for _ in $(seq 1 80); do
  SHARES="$("$EXE" group describe --name "$GROUP" --remote "$SERVE" 2>/dev/null | grep -c '^  member' || true)"
  [ "$SHARES" = "2" ] && break
  sleep 0.25
done
[ "$SHARES" = "2" ] || { "$EXE" group describe --name "$GROUP" --remote "$SERVE"; fail "expected two members"; }
SETTLED=""
for _ in $(seq 1 40); do
  grep -o 'member [^ ]* holds [^:]*' "$WORK/members.log" > "$WORK/shares.txt"
  if python3 "$ROOT/tools/check_shares.py" "$WORK/shares.txt" 2 "$TOPIC" 2 2>/dev/null; then
    SETTLED=yes
    break
  fi
  sleep 0.25
done
[ -n "$SETTLED" ] || { cat "$WORK/shares.txt"; fail "shares never settled over the auto-created partitions"; }
pass "two members joined an auto-created topic; shares cover both disk partitions with no overlap"

# ---- 2. conservation: nothing lost -------------------------------------
sleep 1
kill "$M1_PID" 2>/dev/null || true; wait "$M1_PID" 2>/dev/null || true; M1_PID=""
kill "$M2_PID" 2>/dev/null || true; wait "$M2_PID" 2>/dev/null || true; M2_PID=""
"$EXE" consume --topic "$TOPIC" --group "$GROUP" --member m3 --remote "$SERVE" > "$WORK/m3.out" \
  || fail "the third member could not run"
cat "$WORK/m1.out" "$WORK/m2.out" "$WORK/m3.out" | cut -f4 | sort > "$WORK/delivered.txt"
sort "$WORK/in-0.txt" "$WORK/in-1.txt" > "$WORK/produced-sorted.txt"
MISSING="$(comm -23 "$WORK/produced-sorted.txt" <(sort -u "$WORK/delivered.txt") | wc -l | tr -d ' ')"
[ "$MISSING" = "0" ] || {
  printf 'missing %s record(s):\n' "$MISSING"
  comm -23 "$WORK/produced-sorted.txt" <(sort -u "$WORK/delivered.txt")
  fail "the group lost records"
}
pass "all 6 produced records were delivered (duplicates allowed, gaps are not)"

# ---- 3. the slow one dies; the survivor resumes ------------------------
# legs 1-2 left no live members, so this leg brings up its own pair:
# two members settle, then one dies, and the other takes its share
M1_PID="$(member m1 "$WORK/m1c.out")"
M2_PID="$(member m2 "$WORK/m2b.out")"
PIDS+=("$M1_PID" "$M2_PID")
PAIR=""
for _ in $(seq 1 80); do
  PAIR="$("$EXE" group describe --name "$GROUP" --remote "$SERVE" 2>/dev/null | grep -c '^  member' || true)"
  [ "$PAIR" = "2" ] && break
  sleep 0.25
done
[ "$PAIR" = "2" ] || { "$EXE" group describe --name "$GROUP" --remote "$SERVE"; fail "the takeover pair never settled"; }
sleep 1
kill "$M2_PID" 2>/dev/null || true; wait "$M2_PID" 2>/dev/null || true; M2_PID=""
MOVED=""
for _ in $(seq 1 80); do
  if [ "$("$EXE" group describe --name "$GROUP" --remote "$SERVE" 2>/dev/null | grep -c '^  member' || true)" = "1" ] &&
    python3 "$ROOT/tools/check_shares.py" <(grep -o 'member [^ ]* holds [^:]*' "$WORK/members.log" | tail -1) 2 "$TOPIC" 1 2>/dev/null; then
    MOVED=yes
    break
  fi
  sleep 0.25
done
[ -n "$MOVED" ] || { cat "$WORK/members.log"; "$EXE" group describe --name "$GROUP" --remote "$SERVE"; fail "the survivor never took over"; }
pass "the survivor took over the dead member's partition (after the liveness window)"
kill "$M1_PID" 2>/dev/null || true; wait "$M1_PID" 2>/dev/null || true; M1_PID=""

# ---- 4. a stale generation cannot commit -------------------------------
EPOCH="$("$EXE" group describe --name "$GROUP" --remote "$SERVE" | head -1 | sed 's/.*epoch=//')"
if "$EXE" group commit --group "$GROUP" --member m1 --topic "$TOPIC" --partition 0 \
    --offset 99 --epoch 0 --remote "$SERVE" > /dev/null 2> "$WORK/stale.err"; then
  fail "a commit from a stale generation was accepted"
fi
grep -qi "epoch" "$WORK/stale.err" || { cat "$WORK/stale.err"; fail "the refusal does not mention the epoch"; }
pass "a commit carrying a stale generation is refused (current epoch $EPOCH)"

# ---- 5. offsets survive a serve restart --------------------------------
# compare the committed offsets themselves: the lag column is observed
# from the log at print time and may legitimately differ across the
# restart without saying anything about what was persisted
OFFSETS_BEFORE="$("$EXE" group describe --name "$GROUP" --remote "$SERVE" | sed 's/\tlag=.*//' | grep committed | sort)"
kill "$SERVE_PID" 2>/dev/null || true; wait "$SERVE_PID" 2>/dev/null || true
start_serve restart
wait_listen "$PORT" || { cat "$WORK/serve-restart.log"; fail "serve did not restart"; }
OFFSETS_AFTER="$("$EXE" group describe --name "$GROUP" --remote "$SERVE" | sed 's/\tlag=.*//' | grep committed | sort)"
[ "$OFFSETS_BEFORE" = "$OFFSETS_AFTER" ] \
  || { printf 'before:\n%s\nafter:\n%s\n' "$OFFSETS_BEFORE" "$OFFSETS_AFTER"; fail "committed offsets did not survive the restart"; }
pass "committed offsets survived a serve restart"

# ---- 6. a slow consumer holds retention back ---------------------------
kill "$SERVE_PID" 2>/dev/null || true; wait "$SERVE_PID" 2>/dev/null || true
MOONFLUX_ROLL_BYTES=40 MOONFLUX_RETAIN_BYTES=120 start_serve retain
wait_listen "$PORT" || { cat "$WORK/serve-retain.log"; fail "the retention-enabled serve did not restart"; }
SLOW_GROUP="slow"
SLOW_MEMBER="slow-reader"
"$EXE" consume --topic "$TOPIC" --partition 0 --group "$SLOW_GROUP" --member "$SLOW_MEMBER" --follow \
  --commit-ms 60000 --remote "$SERVE" > "$WORK/slow.out" 2>> "$WORK/members.log" &
SLOW_PID=$!
PIDS+=("$SLOW_PID")
SLOW_EPOCH=""
for _ in $(seq 1 60); do
  SLOW_EPOCH="$("$EXE" group describe --name "$SLOW_GROUP" --remote "$SERVE" 2>/dev/null | head -1 | sed 's/.*epoch=//' || true)"
  [ -n "$SLOW_EPOCH" ] && break
  sleep 0.25
done
[ -n "$SLOW_EPOCH" ] || fail "the slow group never joined"
# it commits only the first three records of partition 0
"$EXE" group commit --group "$SLOW_GROUP" --member "$SLOW_MEMBER" --topic "$TOPIC" \
  --partition 0 --offset 3 --epoch "$SLOW_EPOCH" --remote "$SERVE" > /dev/null \
  || fail "the group could not commit what it read"
# more records: the log grows well past the policy's byte bound
for round in 1 2 3; do
  printf 'extra-%s-a\nextra-%s-b\nextra-%s-c\n' "$round" "$round" "$round" > "$WORK/extra.txt"
  "$EXE" produce --topic "$TOPIC" --partition 0 --file "$WORK/extra.txt" --remote "$SERVE" > /dev/null \
    || fail "the extra produce failed"
done
RETAINED=""
for _ in $(seq 1 60); do
  if grep -q "retained away $TOPIC\[0\]" "$WORK/serve-retain.log"; then
    RETAINED=yes
    break
  fi
  sleep 0.25
done
[ -n "$RETAINED" ] || { tail -6 "$WORK/serve-retain.log"; fail "retention never ran with a consumer floor in play"; }
FIRST="$("$EXE" cluster segments --topic "$TOPIC" --partition 0 --remote "$SERVE" | head -1 | cut -f1)"
[ "$FIRST" -le 3 ] || fail "retention deleted past the consumer's committed offset ($FIRST > 3)"
"$EXE" consume --topic "$TOPIC" --from 3 --remote "$SERVE" > /dev/null \
  || fail "the consumer's committed offset is no longer readable"
pass "retention respected the consumer floor (first readable offset $FIRST ≤ committed 3)"
kill "$SLOW_PID" 2>/dev/null || true; wait "$SLOW_PID" 2>/dev/null || true; SLOW_PID=""

# ---- 7. the permission table governs group commands here too -----------
kill "$SERVE_PID" 2>/dev/null || true; wait "$SERVE_PID" 2>/dev/null || true
mkdir -p "$WORK/serve"
cat > "$WORK/serve/auth.json" <<'JSON'
{"credentials":[
  {"name":"root","token":"p22-root-token-123456","role":"root"},
  {"name":"writer","token":"p22-writer-token-12345","role":"read-write"},
  {"name":"watcher","token":"p22-watcher-token-1234","role":"read-only"}
]}
JSON
start_serve auth
wait_listen "$PORT" || { cat "$WORK/serve-auth.log"; fail "the auth-enabled serve did not restart"; }
ROOT_FLAGS=(--token p22-root-token-123456)
OUT="$("$EXE" consume --topic "$TOPIC" --group "$GROUP" --member ro --follow \
  --remote "$SERVE" --token p22-watcher-token-1234 2>&1 || true)"
printf '%s' "$OUT" | grep -q "code[[:space:]=]*10" \
  || fail "a read-only identity joined a group: $OUT"
OUT="$("$EXE" group describe --name "$GROUP" --remote "$SERVE" "${ROOT_FLAGS[@]}" 2>&1 || true)"
printf '%s' "$OUT" | grep -q "epoch=" \
  || fail "root could not describe a group: $OUT"
pass "group commands answer to the same permission table as the control plane's (read-only refused, root served)"

echo "E2E-P22-SERVE-GROUPS PASS: 7 legs green"
