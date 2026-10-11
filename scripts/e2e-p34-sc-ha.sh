#!/bin/bash
# E2E-P34-SC-HA: 控制面 HA 与备份/恢复（P34，决策 74）
#
# 这一条门禁对着 docs/production-readiness.md §3 的**第一风险**：控制面是单进程、
# 元数据是单文件，SC 挂了就没人建主题/协调消费组/提名 leader，SC 磁盘坏了声明就没了。
#
# 断言的是行为，不是设计意图：
#   1  快照可移植：backup 出来的文档能在**空目录**里恢复出同样的声明
#   2  恢复是新修订：revision = max(本地, 快照) + 1（单调，绝不回退）
#   3  校验和：篡改过的快照按名拒绝（"the file is corrupt"）
#   4  回退保护：快照比本地旧时按名拒绝，--force 才允许
#   5  非快照文档被拒（kind 检查：不会把别人的 JSON 当集群状态写进去）
#   6  HA 默认关闭且**明示**（不带 --ha 时行为与从前完全一致）
#   7  active/standby：第二个 SC 成为 standby，拒绝命令并**指名 active 地址**
#   8  接管：杀掉 active 后，standby 在租约内接管（epoch +1）并能写
#   9  围栏：旧 active 回归后成为 standby，它的写入**不落盘**（元数据不变）
#  10  步下：active 被暂停到租约过期、第三个 SC 接管后，恢复的旧 active 记录 STEPPED DOWN 并继续拒绝
#  11  坏租约文件：SC 拒绝猜测（按名失败），而不是静默认为"没人持有"
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

EXE="${MOONFLUX_EXE:-$ROOT/_build/native/debug/build/apps/cli/cli.exe}"
WORK="$(mktemp -d)"
PASS=0
FAIL=0
PIDS=""

fail() { echo "E2E-P34-SC-HA FAIL: $*" >&2; FAIL=$((FAIL + 1)); }
pass() { echo "E2E-P34-SC-HA PASS: $*"; PASS=$((PASS + 1)); }

cleanup() {
  # the pid list lives in a FILE because `start_sc` is called through command
  # substitution (a subshell), where an appended-to variable would be lost —
  # and a leaked control plane holds the lease the next leg wants
  if [ -f "$WORK/pids" ]; then
    for pid in $(cat "$WORK/pids"); do
      kill "$pid" 2>/dev/null
    done
  fi
  wait 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

# start_sc <data-dir> <port> [extra flags...] -> echoes the pid
start_sc() {
  local dir="$1" port="$2"
  shift 2
  "$EXE" sc --data-dir "$dir" --listen "127.0.0.1:$port" "$@" > "$WORK/sc-$port.log" 2>&1 &
  local pid=$!
  echo "$pid" >> "$WORK/pids"
  echo "$pid"
}

# wait_for <file> <pattern> <tenths> -> 0 when the pattern shows up
wait_for() {
  local file="$1" pattern="$2" tenths="$3" i=0
  while [ "$i" -lt "$tenths" ]; do
    grep -q "$pattern" "$file" 2>/dev/null && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

[ -x "$EXE" ] || { echo "missing $EXE (build first)" >&2; exit 1; }

# ---------------------------------------------------------------- 1. backup
D="$WORK/origin"
printf '%s' '{"name":"p34","functions":[{"name":"shout","params":["s"],"body":"upper(s)"}]}' > "$WORK/fns-a.json"
"$EXE" function-set create --data-dir "$D" --file "$WORK/fns-a.json" \
  > /dev/null 2>&1 || fail "1: could not seed a function set"
P1=19601
A_PID=$(start_sc "$D" "$P1" --ha)
wait_for "$WORK/sc-$P1.log" "ACTIVE" 100 || { cat "$WORK/sc-$P1.log"; fail "1: the first control plane never became active"; }
"$EXE" topic create --remote "127.0.0.1:$P1" --name orders --partitions 2 --replication-factor 1 \
  > /dev/null 2>&1 || fail "1: could not declare a topic through the active control plane"
"$EXE" cluster metadata backup --data-dir "$D" --out "$WORK/snapshot.json" > /dev/null 2>&1 ||
  fail "1: backup failed"
grep -q '"kind": "moonflux.metadata-snapshot"' "$WORK/snapshot.json" ||
  fail "1: the snapshot does not declare its kind"
grep -q '"checksum"' "$WORK/snapshot.json" || fail "1: the snapshot has no checksum"

D2="$WORK/restored"
"$EXE" cluster metadata restore --data-dir "$D2" --in "$WORK/snapshot.json" > "$WORK/restore.out" 2>&1 ||
  { cat "$WORK/restore.out"; fail "1: restore into an empty dir failed"; }
"$EXE" cluster metadata show --data-dir "$D2" > "$WORK/restored.show" 2>&1
grep -q "orders	partitions=2	rf=1" "$WORK/restored.show" || { cat "$WORK/restored.show"; fail "1: the topic declaration did not survive the round trip"; }
grep -q "p34	revision=1" "$WORK/restored.show" || fail "1: the function set did not survive the round trip"
pass "1. a snapshot restores into an empty data dir with the same declarations"

# ---- 2. the restore is a NEW revision, and never goes backwards -----------
ORIG_VERSION=$("$EXE" cluster metadata show --data-dir "$D" 2>/dev/null | awk '/^revision/{print $2}')
RESTORED_VERSION=$("$EXE" cluster metadata show --data-dir "$D2" 2>/dev/null | awk '/^revision/{print $2}')
[ -n "$RESTORED_VERSION" ] && [ "$RESTORED_VERSION" -gt "$ORIG_VERSION" ] ||
  fail "2: restore did not advance the revision ($ORIG_VERSION -> $RESTORED_VERSION)"
pass "2. restore writes a new revision ($ORIG_VERSION -> $RESTORED_VERSION), so nobody sees it go backwards"

# ---- 3. a tampered snapshot is refused by name ---------------------------
python3 - "$WORK/snapshot.json" "$WORK/tampered.json" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
doc["metadata"]["topics"][0]["partitions"] = 9   # the payload changes, the checksum does not
json.dump(doc, open(sys.argv[2], "w"))
PY
if "$EXE" cluster metadata restore --data-dir "$WORK/tampered-target" --in "$WORK/tampered.json" > /dev/null 2> "$WORK/tampered.err"; then
  fail "3: a tampered snapshot was accepted"
else
  grep -q "checksum mismatch" "$WORK/tampered.err" || { cat "$WORK/tampered.err"; fail "3: the refusal does not name the checksum"; }
  pass "3. a tampered snapshot is refused by name (checksum mismatch)"
fi

# ---- 4. a snapshot older than the node is refused without --force --------
"$EXE" cluster metadata backup --data-dir "$D2" --out "$WORK/snapshot2.json" > /dev/null 2>&1
printf '%s' '{"name":"p34b","functions":[{"name":"quiet","params":["s"],"body":"lower(s)"}]}' > "$WORK/fns-b.json"
"$EXE" function-set create --data-dir "$D2" --file "$WORK/fns-b.json" \
  > /dev/null 2>&1 || fail "4: could not add the newer declaration the refusal is about"
if "$EXE" cluster metadata restore --data-dir "$D2" --in "$WORK/snapshot2.json" > /dev/null 2> "$WORK/back.err"; then
  fail "4: a snapshot from an older revision was accepted without --force"
else
  grep -q "would go backwards" "$WORK/back.err" || { cat "$WORK/back.err"; fail "4: the refusal does not name the revision problem"; }
  pass "4. an older snapshot is refused by name, and only --force discards the newer declarations"
fi
"$EXE" cluster metadata restore --data-dir "$D2" --in "$WORK/snapshot2.json" --force > /dev/null 2>&1 ||
  fail "4: --force did not allow the restore"
FORCED=$("$EXE" cluster metadata show --data-dir "$D2" 2>/dev/null | awk '/^revision/{print $2}')
[ "$FORCED" -gt "$RESTORED_VERSION" ] ||
  fail "4: a forced restore went backwards ($RESTORED_VERSION -> $FORCED)"
pass "4b. --force restores, and the result is still a new revision ($FORCED)"

# ---- 5. something that is not a snapshot is refused ----------------------
printf '%s' '{"apiVersion":"moonflux.io/v1alpha1","kind":"Pipeline"}' > "$WORK/not-a-snapshot.json"
if "$EXE" cluster metadata restore --data-dir "$WORK/not-a-snapshot-target" --in "$WORK/not-a-snapshot.json" > /dev/null 2> "$WORK/kind.err"; then
  fail "5: a non-snapshot document was accepted"
else
  grep -q "not a 'moonflux.metadata-snapshot'" "$WORK/kind.err" ||
    { cat "$WORK/kind.err"; fail "5: the refusal does not name the kind it wanted"; }
  pass "5. a document that is not a snapshot is refused by kind"
fi

# ---- 6. HA off by default, and it says so -------------------------------
P2=19602
OFF_PID=$(start_sc "$WORK/solo" "$P2")
wait_for "$WORK/sc-$P2.log" "control-plane HA disabled" 100 ||
  { cat "$WORK/sc-$P2.log"; fail "6: a control plane without --ha did not announce that HA is off"; }
"$EXE" topic create --remote "127.0.0.1:$P2" --name solo --partitions 1 --replication-factor 1 \
  > /dev/null 2>&1 || fail "6: a single control plane (no --ha) could not serve a write"
pass "6. without --ha the mode is announced as DISABLED and behaves exactly as before"
kill "$OFF_PID" 2>/dev/null

# ---- 7-9. active/standby, takeover, fencing ------------------------------
DH="$WORK/ha"
P3=19603
P4=19604
H1=$(start_sc "$DH" "$P3" --ha)
wait_for "$WORK/sc-$P3.log" "is ACTIVE" 100 || { cat "$WORK/sc-$P3.log"; fail "7: the first control plane never became active"; }
H2=$(start_sc "$DH" "$P4" --ha)
wait_for "$WORK/sc-$P4.log" "is STANDBY" 100 || { cat "$WORK/sc-$P4.log"; fail "7: the second control plane never became standby"; }
"$EXE" topic create --remote "127.0.0.1:$P3" --name before --partitions 1 --replication-factor 1 \
  > /dev/null 2>&1 || fail "7: the active control plane could not serve a write"
if "$EXE" topic create --remote "127.0.0.1:$P4" --name via-standby --partitions 1 --replication-factor 1 \
    > /dev/null 2> "$WORK/standby.err"; then
  fail "7: the standby served a write"
else
  grep -q "127.0.0.1:$P3" "$WORK/standby.err" ||
    { cat "$WORK/standby.err"; fail "7: the standby refusal does not name the active address"; }
  pass "7. the standby refuses every command and names the active address"
fi

kill "$H1" 2>/dev/null
wait_for "$WORK/sc-$P4.log" "is ACTIVE" 150 ||
  { tail -3 "$WORK/sc-$P4.log"; fail "8: the standby did not take over within the lease window"; }
"$EXE" topic create --remote "127.0.0.1:$P4" --name after --partitions 1 --replication-factor 1 \
  > /dev/null 2>&1 || fail "8: the new active could not serve a write"
EPOCH_AFTER=$(python3 -c "import json;print(json.load(open('$DH/sc-lease.json'))['epoch'])")
[ "$EPOCH_AFTER" -ge 2 ] ||
  fail "8: the takeover did not bump the lease epoch (got $EPOCH_AFTER)"
pass "8. the standby took over within the lease window, bumped the epoch to $EPOCH_AFTER, and serves writes"

H3=$(start_sc "$DH" "$P3" --ha)
wait_for "$WORK/sc-$P3.log" "is STANDBY" 100 ||
  { tail -3 "$WORK/sc-$P3.log"; fail "9: the restarted control plane did not become standby"; }
BEFORE_TOPICS=$("$EXE" cluster metadata show --data-dir "$DH" 2>/dev/null | awk '/^topics/{print $2}')
if "$EXE" topic create --remote "127.0.0.1:$P3" --name from-the-old-one --partitions 1 --replication-factor 1 \
    > /dev/null 2> "$WORK/stale.err"; then
  fail "9: a stale control plane wrote a declaration"
fi
AFTER_TOPICS=$("$EXE" cluster metadata show --data-dir "$DH" 2>/dev/null | awk '/^topics/{print $2}')
[ "$BEFORE_TOPICS" = "$AFTER_TOPICS" ] ||
  fail "9: the stale control plane changed the metadata ($BEFORE_TOPICS -> $AFTER_TOPICS)"
pass "9. a control plane that lost the lease serves nothing and changes nothing ($AFTER_TOPICS topics before and after)"

# ---- 10. a paused active loses the lease and cannot write ----------------
# The leg used to wait for the string "STEPPED DOWN" — and that was a race I
# wrote myself: when a control plane wakes after its lease expired, finding
# the rival's lease still current (step down) and finding it expired (take it
# back, at a NEW epoch) are BOTH legitimate. On the macOS runner it took the
# second path and the leg failed while the system behaved correctly.
#
# So the leg asserts the invariant instead of one of two outcomes: whatever
# this control plane did when it woke, a write it makes must agree with the
# lease — it may write only while the lease names it — and a refused write
# must leave the metadata untouched and say why.
kill "$H3" 2>/dev/null
sleep 0.3
kill -STOP "$H2" 2>/dev/null
sleep 2.0   # longer than the default lease
H4=$(start_sc "$DH" 19605 --ha)
wait_for "$WORK/sc-19605.log" "is ACTIVE" 150 || {
  tail -5 "$WORK/sc-19605.log"
  tail -3 "$WORK/sc-$P4.log"
  fail "10: the third control plane did not take over from a paused active"
}
kill -CONT "$H2" 2>/dev/null
sleep 1.5   # give it a round to see the lease
HOLDER=$(python3 -c "import json;print(json.load(open('$DH/sc-lease.json'))['holder'])")
EPOCH=$(python3 -c "import json;print(json.load(open('$DH/sc-lease.json'))['epoch'])")
BEFORE_T=$("$EXE" cluster metadata show --data-dir "$DH" 2>/dev/null | awk '/^topics/{print $2}')
if "$EXE" topic create --remote "127.0.0.1:$P4" --name from-the-paused-one --partitions 1 --replication-factor 1 \
    > /dev/null 2> "$WORK/paused.err"; then
  [ "$HOLDER" = "127.0.0.1:$P4" ] || {
    tail -5 "$WORK/sc-$P4.log"
    fail "10: a control plane wrote a declaration while the lease named $HOLDER"
  }
  pass "10. the resumed control plane re-acquired the lease (epoch $EPOCH) and wrote only under it"
else
  AFTER_T=$("$EXE" cluster metadata show --data-dir "$DH" 2>/dev/null | awk '/^topics/{print $2}')
  [ "$BEFORE_T" = "$AFTER_T" ] || {
    cat "$WORK/paused.err"
    fail "10: a refused write still changed the metadata ($BEFORE_T -> $AFTER_T)"
  }
  grep -qE "STEPPED DOWN|is STANDBY" "$WORK/sc-$P4.log" || {
    tail -5 "$WORK/sc-$P4.log"
    fail "10: the refusal is unexplained (neither stepped down nor standby)"
  }
  pass "10. a control plane that lost the lease wrote nothing (the lease names $HOLDER) and the metadata is unchanged"
fi

# ---- 11. a corrupt lease is refused, not guessed -------------------------
DC="$WORK/corrupt"
mkdir -p "$DC"
printf '%s' '{"holder": ' > "$DC/sc-lease.json"
if "$EXE" sc --data-dir "$DC" --listen "127.0.0.1:19606" --ha > "$WORK/corrupt.log" 2>&1; then
  :
fi
wait_for "$WORK/corrupt.log" "lease" 50 || true
if grep -q "control-plane lease" "$WORK/corrupt.log"; then
  pass "11. a corrupt lease file is refused by name instead of being guessed at"
else
  cat "$WORK/corrupt.log"
  fail "11: a corrupt lease did not stop the control plane"
fi

echo "E2E-P34-SC-HA: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ] || exit 1
