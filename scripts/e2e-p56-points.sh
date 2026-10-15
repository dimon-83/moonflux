#!/bin/bash
# E2E-P56-POINTS: 多点位（P1-1，决策 115）
#
# 判据来自 docs/dev-plan.md 的 P1-1：**点位清单展开成任务集**，同一模板展开出的
# 任务名唯一、`target` 可分别指定。四条腿：
#
#   1  一份**模板 + 点位清单** → 集群里真的出现 N 个任务，名字各不相同，
#      点位值确实进了每个任务自己的 spec（URL/topic）
#   2  `target` **逐点位生效**：钉在 worker-a 的点位归 worker-a，浮动的归活 worker
#   3  **拒绝**：两个点位要同一个任务名 ⇒ apply 失败并说出 duplicate
#   4  **拒绝**：模板里出现没人供值的占位符（`{ponit}` 这种笔误）⇒ apply 失败并点名
#
# 拒绝腿才是重点：把笔误放进集群的任务集，比一次说得清楚的 apply 失败糟得多。
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

EXE="${MOONFLUX_EXE:-$ROOT/_build/native/debug/build/apps/cli/cli.exe}"
WORK="$(mktemp -d /tmp/moonflux-p56.XXXXXX)"
SC_PORT="${MOONFLUX_P56_SC_PORT:-19771}"
METRICS_PORT="${MOONFLUX_P56_METRICS_PORT:-19772}"
PASS=0

fail() { echo "E2E-P56-POINTS FAIL: $*" >&2; exit 1; }
pass() { echo "E2E-P56-POINTS PASS: $*"; PASS=$((PASS + 1)); }
cleanup() {
  # One scoped operation: every process this gate starts carries its own temp path
  # in its argv. The pid list is deliberately not used (a recycled pid once took a
  # gate down inside its own cleanup — see AGENT.md rule 1).
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
tasks_cli() { "$EXE" pipeline list --remote "$SC" 2>/dev/null; }
sched() { "$EXE" task schedule --remote "$SC" 2>/dev/null; }

# ---- one template, two points -------------------------------------------
cat > "$WORK/points.json" <<'JSON'
{
  "template": {
    "apiVersion": "moonflux.io/v1alpha1",
    "kind": "Pipeline",
    "metadata": {"name": "{name}"},
    "spec": {
      "source": {"type": "topic", "name": "{name}-in", "from": "end"},
      "topic": {"name": "{name}-in"},
      "transforms": [],
      "sink": {"type": "stdout"}
    }
  },
  "points": [
    {"name": "pinned-a", "point": "CN_INLET_COD", "target": "worker-a"},
    {"name": "floating-b", "point": "CN_OUTLET_NH3", "restart": "on-failure"}
  ]
}
JSON

"$EXE" sc --listen "$SC" --data-dir "$WORK/sc" --metrics-listen "127.0.0.1:$METRICS_PORT" \
  > "$WORK/sc.log" 2>&1 &
wait_listen "$SC_PORT" || { cat "$WORK/sc.log"; fail "the control plane did not start"; }
export MOONFLUX_EXE="$EXE"

"$EXE" pipeline apply --points "$WORK/points.json" --remote "$SC" > "$WORK/apply.out" 2> "$WORK/apply.err" ||
  { cat "$WORK/apply.err"; fail "applying a points document failed"; }

"$EXE" runner --data-dir "$WORK/plant" --control "$SC" --worker worker-a \
  > "$WORK/runner.out" 2> "$WORK/runner.err" &

# ---- 1. the fleet became tasks, with the point inside each spec ----------
i=0
while [ "$i" -lt 400 ]; do
  tasks_cli | grep -q "floating-b" && break
  sleep 0.1; i=$((i + 1))
done
for name in pinned-a floating-b; do
  tasks_cli | grep -q "^$name	" ||
    { tasks_cli; fail "1: the fleet did not become a task named $name"; }
done
# the placeholder really landed in each task's OWN topic (the template was not
# applied verbatim, and one task did not overwrite the other)
for name in pinned-a floating-b; do
  tasks_cli | grep "^$name	" | grep -q "topic=$name-in" ||
    { tasks_cli; fail "1: task $name does not carry its own point in its topic"; }
done
pass "1. 一份模板 + 两个点位 → 集群里两个任务（名字各异，且各自带着自己的点位）"

# ---- 2. target is per point ---------------------------------------------
i=0
while [ "$i" -lt 400 ]; do
  sched | grep -q "^pinned-a	.*owner=worker-a" && break
  sleep 0.1; i=$((i + 1))
done
sched | grep "^pinned-a	" | grep -q "owner=worker-a" ||
  { sched; fail "2: the pinned point did not land on its worker"; }
sched | grep "^floating-b	" | grep -q "owner=worker-a" ||
  { sched; fail "2: the floating point was not placed on the live worker"; }
sched | grep "^pinned-a	" | grep -q "target=worker-a" ||
  { sched; fail "2: the pinned point lost its declared target"; }
pass "2. target 逐点位生效（钉住的归 worker-a，浮动的也落到活 worker）"

# ---- 3. two points cannot want one task name ----------------------------
python3 - "$WORK/points.json" "$WORK/dup.json" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
doc["points"][1]["name"] = doc["points"][0]["name"]
json.dump(doc, open(sys.argv[2], "w"))
PY
"$EXE" pipeline apply --points "$WORK/dup.json" --remote "$SC" > "$WORK/dup.out" 2> "$WORK/dup.err"
DUP=$?
[ "$DUP" != "0" ] || { cat "$WORK/dup.out"; fail "3: a duplicate task name was accepted"; }
grep -q "duplicate" "$WORK/dup.err" ||
  { cat "$WORK/dup.err"; fail "3: the refusal does not say the names collide"; }
pass "3. 拒绝：两个点位要同一个任务名 ⇒ apply 失败并点名 duplicate"

# ---- 4. a placeholder nobody supplies is a typo, not a surprise ---------
python3 - "$WORK/points.json" "$WORK/typo.json" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
doc["template"]["spec"]["source"]["url"] = "http://x/{ponit}"
doc["template"]["spec"]["source"]["type"] = "http"
doc["template"]["spec"]["source"]["interval_ms"] = 20000
del doc["template"]["spec"]["source"]["from"]
del doc["template"]["spec"]["source"]["name"]
json.dump(doc, open(sys.argv[2], "w"))
PY
"$EXE" pipeline apply --points "$WORK/typo.json" --remote "$SC" > "$WORK/typo.out" 2> "$WORK/typo.err"
TYPO=$?
[ "$TYPO" != "0" ] || { cat "$WORK/typo.out"; fail "4: an unknown placeholder was accepted"; }
grep -q "unknown placeholder" "$WORK/typo.err" ||
  { cat "$WORK/typo.err"; fail "4: the refusal does not name the placeholder mistake"; }
pass "4. 拒绝：模板里的笔误占位符 ⇒ apply 失败并点名（不把 {ponit} 悄悄带进集群）"

echo "E2E-P56-POINTS: $PASS passed, 0 failed"
release
exit 0
