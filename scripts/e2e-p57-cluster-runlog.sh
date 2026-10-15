#!/bin/bash
# E2E-P57-CLUSTER-RUNLOG: 运行日志进集群（P1-2a，决策 118）
#
# 判据来自 docs/task-cluster-data-plane.md 的 P1-2a：任务的**运行日志**活在集群里，
# 于是 `task logs --remote` 成立。五条腿：
#
#   1  任务经 runner 起 ⇒ 它的事件**落在集群的运行日志主题里**（由数据节点宿主）
#   2  **`task logs --remote <sc>` 读到内容**（控制面只负责告诉谁是 leader，
#      记录在数据节点上——sc 根本不提供数据读，实测是 "unknown command"）
#   3  **边界腿（本片要买的东西）**：杀掉 runner（"那台机器不可达"）之后，
#      已经写入的事件**仍然读得到**——因为真相在集群，不在那台机器上
#   4  **反例腿**：`--data-dir` 口径不变（本地任务日志仍在本地，`task logs --data-dir` 照旧可读）
#   5  **诚实失败腿**：主题没有宿主时，`task logs --remote` **明说**
#      "has no host yet"，而不是把"没人托管"显示成"日志是空的"
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

EXE="${MOONFLUX_EXE:-$ROOT/_build/native/debug/build/apps/cli/cli.exe}"
WORK="$(mktemp -d /tmp/moonflux-p57.XXXXXX)"
SC_PORT="${MOONFLUX_P57_SC_PORT:-19821}"
METRICS_PORT="${MOONFLUX_P57_METRICS_PORT:-19822}"
NODE_PORT="${MOONFLUX_P57_NODE_PORT:-19823}"
PASS=0

fail() { echo "E2E-P57-CLUSTER-RUNLOG FAIL: $*" >&2; exit 1; }
pass() { echo "E2E-P57-CLUSTER-RUNLOG PASS: $*"; PASS=$((PASS + 1)); }
cleanup() {
  # `pkill -f ""` matches EVERY process: refuse to run with nothing in the
  # variable. This cleanup can run on a CI runner shared with the runner agent.
  [ -n "$WORK" ] || return 0
  pkill -9 -f "$WORK" 2>/dev/null
  sleep 0.3
  if pgrep -f "$WORK" > /dev/null 2>&1; then
    echo "WARNING: process(es) survived cleanup, still referencing $WORK:" >&2
    pgrep -fl "$WORK" >&2
  fi
  rm -rf "$WORK"
}
trap 'status=$?; cleanup; exit "$status"' EXIT
release() {
  cleanup
  trap - EXIT
}

[ -x "$EXE" ] || { echo "missing $EXE (build first)" >&2; exit 1; }

wait_listen() {
  local port="$1" tenths="${2:-80}" i=0
  while [ "$i" -lt "$tenths" ]; do
    lsof -i ":$port" -sTCP:LISTEN > /dev/null 2>&1 && return 0
    sleep 0.1; i=$((i + 1))
  done
  return 1
}
SC="127.0.0.1:$SC_PORT"
sched() { "$EXE" task schedule --remote "$SC" 2>/dev/null; }
leader_of() { "$EXE" cluster leader --topic "$1" --remote "$SC" 2>/dev/null; }

cat > "$WORK/t.json" <<'JSON'
{"apiVersion":"moonflux.io/v1alpha1","kind":"Pipeline","metadata":{"name":"logged"},
 "spec":{"source":{"type":"topic","name":"logged-in","from":"end"},"topic":{"name":"logged-in"},
  "transforms":[],"sink":{"type":"stdout"}}}
JSON

"$EXE" sc --listen "$SC" --data-dir "$WORK/sc" --metrics-listen "127.0.0.1:$METRICS_PORT" \
  > "$WORK/sc.log" 2>&1 &
wait_listen "$SC_PORT" || { cat "$WORK/sc.log"; fail "the control plane did not start"; }

# a data node, because the control plane serves no data reads at all
"$EXE" spu --id n1 --listen "127.0.0.1:$NODE_PORT" --data-dir "$WORK/n1" --sc "$SC" \
  > "$WORK/n1.log" 2>&1 &
wait_listen "$NODE_PORT" || { cat "$WORK/n1.log"; fail "the data node did not start"; }
sleep 2
export MOONFLUX_EXE="$EXE"

# The run log is a CLUSTER topic, so it needs a declaration before anything can
# host it (the runner does not declare run logs yet — that is the honest boundary
# recorded with this decision, not a hidden step).
"$EXE" topic create --name logged.run-log --partitions 1 --replication-factor 1 --remote "$SC" \
  > /dev/null 2>&1 || { cat "$WORK/sc.log"; fail "declaring the run log failed"; }

"$EXE" runner --data-dir "$WORK/plant" --control "$SC" --worker w > "$WORK/r.out" 2> "$WORK/r.err" &
# The task goes into the CLUSTER's task set: the runner below is a scheduled
# worker, so the schedule table (and the placement it answers) is the cluster's.
i=0
while [ "$i" -lt 100 ]; do
  "$EXE" pipeline apply -f "$WORK/t.json" --remote "$SC" > /dev/null 2>&1 && break
  sleep 0.1; i=$((i + 1))
done
i=0
while [ "$i" -lt 400 ]; do
  sched | grep -q "^logged	.*state=running" && break
  sleep 0.1; i=$((i + 1))
done
sched | grep -q "^logged	.*state=running" || { sched; cat "$WORK/r.err"; fail "the task did not start"; }
# one more round-trip, so there is more than the run-start event to find
sleep 2

# ---- 1. the events landed on the CLUSTER, at the leader ------------------
LEADER=$(leader_of logged.run-log)
[ -n "$LEADER" ] || { cat "$WORK/sc.log"; fail "1: the run log has no host"; }
"$EXE" consume --topic logged.run-log --from 0 --max 10 --remote "$LEADER" > "$WORK/on-cluster" 2>&1 ||
  { cat "$WORK/on-cluster"; fail "1: reading the run log from its host failed"; }
grep -q "run-start" "$WORK/on-cluster" ||
  { cat "$WORK/on-cluster"; fail "1: the run log on the cluster has no run-start"; }
pass "1. 任务的事件落在**集群**的运行日志主题里（宿主 = ${LEADER}）"

# ---- 2. task logs --remote reads it -------------------------------------
"$EXE" task logs --remote "$SC" --name logged > "$WORK/remote.logs" 2>&1 ||
  { cat "$WORK/remote.logs"; fail "2: task logs --remote failed"; }
grep -q "run-start" "$WORK/remote.logs" ||
  { cat "$WORK/remote.logs"; fail "2: task logs --remote did not show the run log"; }
pass "2. **`task logs --remote <sc>` 读到内容**（控制面给 leader，记录在数据节点）"

# ---- 3. the boundary this slice buys: the node can be gone ---------------
pkill -9 -f "runner --data-dir $WORK/plant" 2>/dev/null
sleep 1
pgrep -f "runner --data-dir $WORK/plant" > /dev/null 2>&1 &&
  fail "3: the runner did not go away"
"$EXE" task logs --remote "$SC" --name logged > "$WORK/after.logs" 2>&1 ||
  { cat "$WORK/after.logs"; fail "3: the log became unreadable when the runner died"; }
grep -q "run-start" "$WORK/after.logs" ||
  { cat "$WORK/after.logs"; fail "3: the previously written events are gone"; }
pass "3. **边界腿**：杀掉 runner（那台机器不可达）后，已写入的事件仍读得到——真相在集群"

# ---- 4. the local口径 is unchanged --------------------------------------
"$EXE" task logs --data-dir "$WORK/plant" --name logged > "$WORK/local.logs" 2>&1 || true
grep -q "run-log events" "$WORK/local.logs" ||
  { cat "$WORK/local.logs"; fail "4: the local task logs path no longer labels the run-log section"; }
pass "4. 反例腿：`--data-dir` 口径不变（本地任务日志仍从本地读，并标注 run-log 段落）"

# ---- 5. no host must not look like an empty log --------------------------
"$EXE" task logs --remote "$SC" --name never-declared > "$WORK/nohost.logs" 2>&1 && \
  fail "5: a run log with no host was reported as readable"
grep -q "has no host yet" "$WORK/nohost.logs" ||
  { cat "$WORK/nohost.logs"; fail "5: the failure does not say the topic has no host"; }
pass "5. 诚实失败腿：主题没有宿主时明说 has no host yet（不是显示成空日志）"

echo "E2E-P57-CLUSTER-RUNLOG: $PASS passed, 0 failed"
release
exit 0
