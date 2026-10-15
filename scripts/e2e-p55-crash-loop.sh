#!/bin/bash
# E2E-P55-CRASH-LOOP: 崩溃循环要可见（P0-3，决策 113）
#
# 判据来自 docs/dev-plan.md 的 P0-3：一个必然失败的任务在 N 次重启后**被显式标出**，
# 而不是只在日志里刷屏。四条腿：
#
#   1  **必然失败的任务被标成 `crash-loop`**，并且**说出多频繁**（"5 run(s) … cannot
#      stay up"）——"它在崩溃循环"没有"多频繁"是一句操作员无法据以行动的话
#   2  **反例腿：健康任务不被标**——一个标记如果会误报就是噪声，而噪声正是真标记
#      被忽略的原因
#   3  **优先级**：操作员已经 `task stop` 过的任务是 `disabled`，不是 `crash-loop`
#      （人已经表过态，平台不该盖过它）
#   4  标记来自**控制面自己看得见的事实**：run 静默而死（offline）、活得短、且密集
#      ——不猜 exit code（控制面从来收不到它）
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

EXE="${MOONFLUX_EXE:-$ROOT/_build/native/debug/build/apps/cli/cli.exe}"
WORK="$(mktemp -d /tmp/moonflux-p55.XXXXXX)"
SC_PORT="${MOONFLUX_P55_SC_PORT:-19761}"
METRICS_PORT="${MOONFLUX_P55_METRICS_PORT:-19762}"
PIDS=""
PASS=0

fail() { echo "E2E-P55-CRASH-LOOP FAIL: $*" >&2; exit 1; }
pass() { echo "E2E-P55-CRASH-LOOP PASS: $*"; PASS=$((PASS + 1)); }
cleanup() {
  for pid in $PIDS; do kill -9 "$pid" 2>/dev/null; done
  pkill -9 -f "$WORK" 2>/dev/null
  wait 2>/dev/null
  sleep 0.3
  # VERIFY the release and say so when it did not happen (iron rule 1): a survivor
  # keeps reporting into whatever control plane listens on that port next
  if pgrep -f "$WORK" > /dev/null 2>&1; then
    echo "E2E-P55-CRASH-LOOP: WARNING: process(es) survived cleanup, still referencing $WORK:" >&2
    pgrep -fl "$WORK" >&2
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

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
wait_sched() {
  local pattern="$1" tenths="${2:-300}" i=0
  while [ "$i" -lt "$tenths" ]; do
    sched | grep -q "$pattern" && return 0
    sleep 0.1; i=$((i + 1))
  done
  return 1
}

# ---- one task that cannot stay up, one that is fine ---------------------
# flappy: a file source that does not exist -> the child registers a run and then
#         exits non-zero, immediately, forever. `restart: always` is the policy
#         that turns one broken task into a storm.
# calm  : an idle topic source, the healthy sibling.
cat > "$WORK/flappy.json" <<JSON
{"apiVersion":"moonflux.io/v1alpha1","kind":"Pipeline","metadata":{"name":"flappy"},
 "spec":{"source":{"type":"file","path":"$WORK/not-here.txt"},"topic":{"name":"flappy-in"},
  "transforms":[],"sink":{"type":"stdout"}}}
JSON
cat > "$WORK/calm.json" <<'JSON'
{"apiVersion":"moonflux.io/v1alpha1","kind":"Pipeline","metadata":{"name":"calm"},
 "spec":{"source":{"type":"topic","name":"calm-in","from":"end"},"topic":{"name":"calm-in"},
  "transforms":[],"sink":{"type":"stdout"}}}
JSON
python3 - "$WORK/set.json" "$WORK/flappy.json" "$WORK/calm.json" <<'PY'
import json, sys
out, flappy, calm = sys.argv[1:4]
json.dump({"pipelines": [
    {"pipeline": "flappy", "spec": json.load(open(flappy)), "target": "any", "restart": "always"},
    {"pipeline": "calm", "spec": json.load(open(calm)), "target": "any", "restart": "on-failure"},
]}, open(out, "w"))
PY

"$EXE" sc --listen "$SC" --data-dir "$WORK/sc" --metrics-listen "127.0.0.1:$METRICS_PORT" \
  > "$WORK/sc.log" 2>&1 &
PIDS="$PIDS $!"
wait_listen "$SC_PORT" || { cat "$WORK/sc.log"; fail "the control plane did not start"; }
export MOONFLUX_EXE="$EXE"

"$EXE" pipeline apply -f "$WORK/set.json" --set --remote "$SC" > "$WORK/apply.out" 2> "$WORK/apply.err" ||
  { cat "$WORK/apply.err"; fail "applying the task set failed"; }

"$EXE" runner --data-dir "$WORK/plant" --control "$SC" --worker plant \
  > "$WORK/runner.out" 2> "$WORK/runner.err" &
PIDS="$PIDS $!"

# ---- 2 (first, because it is the control): the healthy one is NOT marked ---
wait_sched "calm	.*state=running" 400 ||
  { sched; cat "$WORK/runner.err"; fail "2: the healthy task never came up"; }

# ---- 1. the failing one is marked, with its frequency --------------------
wait_sched "flappy	.*state=crash-loop" 900 ||
  { sched; tail -5 "$WORK/plant/logs/flappy.stderr" 2>/dev/null; fail "1: a task that cannot stay up was not marked crash-loop"; }
ROW=$(sched | grep "^flappy	")
echo "$ROW" | grep -q "run(s) ended silently" ||
  { sched; fail "1: the mark does not say how often it happened"; }
echo "$ROW" | grep -q "cannot stay up" ||
  { sched; fail "1: the mark does not say what it means"; }
COUNT=$(echo "$ROW" | sed -E 's/.*state=crash-loop.*reason=([0-9]+) run.*/\1/')
[ -n "$COUNT" ] && [ "$COUNT" -ge 3 ] ||
  { sched; fail "1: the mark's count is not a number >= 3 ($COUNT)"; }
pass "1. 必然失败的任务被标成 **crash-loop**，并说出频率（$COUNT 次静默而死、每次都短命）"

# ---- 2 (conclusion). the healthy sibling stays healthy -------------------
CALM=$(sched | grep "^calm	")
echo "$CALM" | grep -q "state=running" ||
  { sched; fail "2: the healthy task is not running"; }
echo "$CALM" | grep -q "crash-loop" &&
  { sched; fail "2: a healthy task was marked crash-loop (the mark is noise)"; }
pass "2. 反例腿：健康任务**不被标**（仍是 running）——标记不会误报成噪声"

# ---- 3. an operator's decision outranks the platform's observation -------
"$EXE" task stop --remote "$SC" --name flappy > /dev/null 2>&1 ||
  fail "3: stopping the crashing task failed"
wait_sched "flappy	.*state=disabled" 300 ||
  { sched; fail "3: a stopped task is not shown as disabled"; }
pass "3. 优先级：操作员 stop 过的任务是 **disabled**，不是 crash-loop（人已经表过态）"

# ---- 4. and the mark came from what the control plane can see -----------
# The control plane never receives an exit code: the mark is built from runs that
# ended SILENTLY, quickly and densely. Assert the recipe, so a future change that
# starts guessing at exit codes has to argue with this line.
grep -q "CRASH_LOOP_MIN_RUNS" apps/cli/runs.mbt ||
  fail "4: the crash-loop threshold is no longer a named constant"
grep -q "state is Offline" apps/cli/runs.mbt ||
  fail "4: the crash-loop recipe no longer keys on silent deaths"
pass "4. 标记来自控制面自己看得见的事实（静默而死 + 短命 + 密集），不猜 exit code"

echo "E2E-P55-CRASH-LOOP: $PASS passed, 0 failed"
exit 0
