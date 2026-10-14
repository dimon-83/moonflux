#!/bin/bash
# E2E-P52-CONTROL-RECONCILE: 控制面对账循环（P37-5b 的控制面半，决策 100）
#
# 这块是"管理平面/数据平面"里管理平面的核心：控制面持有 desired（任务集文档），
# 从 run 注册表与 worker 心跳知道 actual，把两者对成一张表——该起就起、该停就停、
# 死了按策略、丢主人重分配，**pending 可见不静默**；放置随 worker 心跳应答下发。
#
#   1  `task schedule --remote sc` 打出 desired vs actual：浮动任务被放到活 worker、
#      钉住的任务在它的目标 worker、**目标不存在的任务显示 pending 并说明原因**
#   2  `task stop --remote sc` 改**集群**文档的 desired → 该任务变 disabled、子进程停
#   3  `task start --remote sc` 翻回来 → 又跑起来
#   4  杀掉一个 worker → 它持有的**浮动**任务重分配到活 worker（事件被说出来）；
#      **钉住**的任务不重分配、变 pending（pin 是声明不是偏好）
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

EXE="${MOONFLUX_EXE:-$ROOT/_build/native/debug/build/apps/cli/cli.exe}"
WORK="$(mktemp -d /tmp/moonflux-p52.XXXXXX)"
SC_PORT="${MOONFLUX_P52_SC_PORT:-19721}"
METRICS_PORT="${MOONFLUX_P52_METRICS_PORT:-19722}"
PIDS=""
PASS=0

fail() { echo "E2E-P52-CONTROL-RECONCILE FAIL: $*" >&2; exit 1; }
pass() { echo "E2E-P52-CONTROL-RECONCILE PASS: $*"; PASS=$((PASS + 1)); }
cleanup() {
  for pid in $PIDS; do kill -9 "$pid" 2>/dev/null; done
  wait 2>/dev/null
  # children may still be flushing their last write when the kill lands; without
  # this the rm races them and prints "Directory not empty" noise
  sleep 0.3
  rm -rf "$WORK"
}
trap cleanup EXIT

[ -x "$EXE" ] || { echo "missing $EXE (build first)" >&2; exit 1; }
"$ROOT/scripts/build-operators.sh" > /dev/null 2>&1 || fail "could not build operator modules"

wait_listen() {
  local port="$1" tenths="${2:-80}" i=0
  while [ "$i" -lt "$tenths" ]; do
    lsof -i ":$port" -sTCP:LISTEN > /dev/null 2>&1 && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}
sched() { "$EXE" task schedule --remote "127.0.0.1:$SC_PORT" 2>/dev/null; }
runs() { "$EXE" run list --remote "127.0.0.1:$SC_PORT" 2>/dev/null; }
# wait_sched <grep pattern> <tenths>
wait_sched() {
  local pattern="$1" tenths="${2:-200}" i=0
  while [ "$i" -lt "$tenths" ]; do
    sched | grep -q "$pattern" && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

cat > "$WORK/set.json" <<'JSON'
{"pipelines":[
 {"pipeline":"floater","restart":"on-failure",
  "spec":{"apiVersion":"moonflux.io/v1alpha1","kind":"Pipeline","metadata":{"name":"floater"},
   "spec":{"source":{"type":"topic","name":"in-f","from":"beginning"},"topic":{"name":"in-f"},
    "transforms":[],"sink":{"type":"stdout"}}}},
 {"pipeline":"pinned-a","target":"worker-a",
  "spec":{"apiVersion":"moonflux.io/v1alpha1","kind":"Pipeline","metadata":{"name":"pinned-a"},
   "spec":{"source":{"type":"topic","name":"in-a","from":"beginning"},"topic":{"name":"in-a"},
    "transforms":[],"sink":{"type":"stdout"}}}},
 {"pipeline":"pinned-gone","target":"worker-zzz",
  "spec":{"apiVersion":"moonflux.io/v1alpha1","kind":"Pipeline","metadata":{"name":"pinned-gone"},
   "spec":{"source":{"type":"topic","name":"in-g","from":"beginning"},"topic":{"name":"in-g"},
    "transforms":[],"sink":{"type":"stdout"}}}}
]}
JSON

"$EXE" sc --listen "127.0.0.1:$SC_PORT" --data-dir "$WORK/sc" \
  --metrics-listen "127.0.0.1:$METRICS_PORT" > "$WORK/sc.log" 2>&1 &
PIDS="$PIDS $!"
wait_listen "$SC_PORT" || { cat "$WORK/sc.log"; fail "the control plane did not start"; }
export MOONFLUX_EXE="$EXE"

mkdir -p "$WORK/da" "$WORK/db"
# two workers: they beat the control plane and take their placement from the reply
"$EXE" runner --data-dir "$WORK/da" --control "127.0.0.1:$SC_PORT" --worker worker-a \
  > "$WORK/ra.out" 2> "$WORK/ra.err" &
RA=$!
PIDS="$PIDS $RA"
"$EXE" runner --data-dir "$WORK/db" --control "127.0.0.1:$SC_PORT" --worker worker-b \
  > "$WORK/rb.out" 2> "$WORK/rb.err" &
RB=$!
PIDS="$PIDS $RB"
sleep 2

# the CLUSTER's desired state (the workers adopt it on their next beat, P11)
"$EXE" pipeline apply -f "$WORK/set.json" --set --remote "127.0.0.1:$SC_PORT" > /dev/null 2>&1 ||
  fail "applying the task set to the cluster failed"

# ---- 1. the reconciliation table ---------------------------------------
wait_sched "floater	.*state=running" 250 ||
  { sched; cat "$WORK/ra.err" "$WORK/rb.err"; fail "1: the floating task never ran"; }
# pinned-a lands on its declared worker
wait_sched "pinned-a	target=worker-a	owner=worker-a	state=running" 250 ||
  { sched; fail "1: the pinned task did not run on its target worker"; }
# pinned-gone has no such worker: PENDING, with the reason naming the pin. The
# point of the table is that this gap is visible rather than silence.
wait_sched "pinned-gone	.*state=pending" 100 ||
  { sched; fail "1: a task pinned to a missing worker is not shown as pending"; }
sched | grep "pinned-gone" | grep -q "a pin is a declaration" ||
  { sched; fail "1: the pending row does not say why (a pin is not reassigned)"; }
pass "1. 对账表：floater 被放到活 worker、pinned-a 在 worker-a、pinned-gone **pending 且说明原因**"

# ---- 2. task stop --remote flips the CLUSTER's desired state -----------
"$EXE" task stop --remote "127.0.0.1:$SC_PORT" --name floater > "$WORK/stop.out" 2>&1 ||
  { cat "$WORK/stop.out"; fail "2: task stop --remote failed"; }
grep -q "revision" "$WORK/stop.out" ||
  { cat "$WORK/stop.out"; fail "2: task stop --remote did not report the cluster revision it wrote"; }
wait_sched "floater	.*state=disabled" 200 ||
  { sched; fail "2: the stopped task is not disabled in the table"; }
# and the child really stopped (graceful)
wait_run() {
  local pattern="$1" tenths="${2:-200}" i=0
  while [ "$i" -lt "$tenths" ]; do
    runs | grep -q "$pattern" && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}
wait_run "task=floater	state=stopped" 200 ||
  { runs; fail "2: the child did not stop gracefully after task stop --remote"; }
pass "2. task stop --remote → 集群 desired 翻位（报告修订）、表里 disabled、子进程优雅停止"

# ---- 3. task start --remote brings it back -----------------------------
"$EXE" task start --remote "127.0.0.1:$SC_PORT" --name floater > /dev/null 2>&1 ||
  fail "3: task start --remote failed"
wait_sched "floater	.*state=running" 250 ||
  { sched; cat "$WORK/ra.err" "$WORK/rb.err"; fail "3: the started task did not come back"; }
pass "3. task start --remote → 又跑起来"

# ---- 4. losing a worker: floating work moves, a pin does not -----------
OWNER=$(sched | grep "^floater" | sed -E 's/.*owner=([^	]*).*/\1/')
[ -n "$OWNER" ] && [ "$OWNER" != "-" ] || { sched; fail "4: the floating task has no owner"; }
if [ "$OWNER" = "worker-b" ]; then
  VICTIM=$RB
  VICTIM_ID=worker-b
  SURVIVOR=worker-a
else
  VICTIM=$RA
  VICTIM_ID=worker-a
  SURVIVOR=worker-b
fi
kill -9 "$VICTIM" 2>/dev/null
PIDS="$(echo "$PIDS" | tr ' ' '\n' | grep -v "^$VICTIM$" | tr '\n' ' ')"
# the floating task is reassigned to the survivor, and the move is SAID
wait_sched "floater	.*owner=$SURVIVOR	state=running" 400 ||
  { sched; cat "$WORK/ra.err" "$WORK/rb.err"; fail "4: the floating task was not reassigned to $SURVIVOR"; }
# the pinned task's worker is gone: it must NOT move, and must be pending
if [ "$VICTIM_ID" = "worker-a" ]; then
  wait_sched "pinned-a	.*state=pending" 400 ||
    { sched; fail "4: a task pinned to a dead worker was moved or hidden"; }
fi
pass "4. 丢 worker：浮动任务重分配到 ${SURVIVOR}（事件被说出），钉住的任务不重分配"

echo "E2E-P52-CONTROL-RECONCILE: $PASS passed, 0 failed"
