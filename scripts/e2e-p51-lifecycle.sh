#!/bin/bash
# E2E-P51-LIFECYCLE: task start/stop 写半 + runner 对账（P37-5a 补全，决策 98）
#
# `task stop` 把任务的 `enabled` 位翻成 false、`task start` 翻回 true；runner 每 500ms
# 重读文档并对账——该起的起、该停的优雅停（SIGTERM → run-stop → stopped）。这是 ② 的写半
# 和 ③ 的 worker 侧对账。控制面侧（--remote、pending 可见、丢主人重分配）在它之上、尚未做。
#
#   1  起的任务 running
#   2  task stop → 子进程优雅停止（stopped，不是 offline），且扛过回收窗口
#   3  task start → runner 对账重新起一个**新 pid** 的 running 条目
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

EXE="${MOONFLUX_EXE:-$ROOT/_build/native/debug/build/apps/cli/cli.exe}"
WORK="$(mktemp -d /tmp/moonflux-p51.XXXXXX)"
SC_PORT="${MOONFLUX_P51_SC_PORT:-19711}"
METRICS_PORT="${MOONFLUX_P51_METRICS_PORT:-19712}"
PIDS=""
PASS=0

fail() { echo "E2E-P51-LIFECYCLE FAIL: $*" >&2; exit 1; }
pass() { echo "E2E-P51-LIFECYCLE PASS: $*"; PASS=$((PASS + 1)); }
cleanup() {
  for pid in $PIDS; do kill -9 "$pid" 2>/dev/null; done
  wait 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

[ -x "$EXE" ] || { echo "missing $EXE (build first)" >&2; exit 1; }

wait_listen() {
  local port="$1" tenths="${2:-80}" i=0
  while [ "$i" -lt "$tenths" ]; do
    lsof -i ":$port" -sTCP:LISTEN > /dev/null 2>&1 && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}
runs() { "$EXE" run list --remote "127.0.0.1:$SC_PORT" 2>/dev/null; }
wait_run() {
  local pattern="$1" tenths="${2:-120}" i=0
  while [ "$i" -lt "$tenths" ]; do
    runs | grep -q "$pattern" && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}
running_pid() { runs | grep "task=$1	state=running" | head -1 | sed -E 's/.*pid=([0-9]+).*/\1/'; }

D="$WORK/d"
mkdir -p "$D"
cat > "$WORK/relay.json" <<'JSON'
{"apiVersion":"moonflux.io/v1alpha1","kind":"Pipeline","metadata":{"name":"relay"},
 "spec":{"source":{"type":"topic","name":"relay-in","from":"beginning"},"topic":{"name":"relay-in"},
 "transforms":[],"sink":{"type":"stdout"}}}
JSON
"$EXE" pipeline apply -f "$WORK/relay.json" --data-dir "$D" > /dev/null 2>&1 ||
  fail "apply failed"

"$EXE" sc --listen "127.0.0.1:$SC_PORT" --data-dir "$WORK/sc" \
  --metrics-listen "127.0.0.1:$METRICS_PORT" > "$WORK/sc.log" 2>&1 &
PIDS="$PIDS $!"
wait_listen "$SC_PORT" || { cat "$WORK/sc.log"; fail "sc did not start"; }
export MOONFLUX_EXE="$EXE"

"$EXE" runner --data-dir "$D" --control "127.0.0.1:$SC_PORT" > "$WORK/r.out" 2> "$WORK/r.err" &
RUNNER=$!
PIDS="$PIDS $RUNNER"

# ---- 1. the task is running --------------------------------------------
wait_run "task=relay	state=running" 120 ||
  { runs; cat "$WORK/r.err"; fail "1: the task did not start"; }
PID1=$(running_pid relay)
[ -n "$PID1" ] || { runs; fail "1: no pid for the running task"; }
pass "1. 任务 running（pid=${PID1}）"

# ---- 1b. idle is not death ---------------------------------------------
# The relay's input topic is quiet, so it has nothing to process. Without the
# idle heartbeat the run registry's 3s liveness window reaps it as `offline` — a
# live task declared dead (found in docker, fixed in decision 105). Wait past the
# window and it must still be running.
sleep 5
running_pid relay | grep -q . ||
  { runs; fail "1b: an IDLE task was reaped as offline (the idle heartbeat regressed)"; }
pass "1b. 空闲任务过了 3s 回收窗口仍 running（idle 心跳，决策 105）"

# ---- 2. task stop stops it gracefully ----------------------------------
"$EXE" task stop --name relay --data-dir "$D" > /dev/null 2>&1 ||
  fail "2: task stop failed"
wait_run "task=relay	state=stopped" 120 ||
  { runs; cat "$WORK/r.err"; fail "2: the task did not stop gracefully"; }
pass "2. task stop → 优雅停止（stopped，不是 offline）"

# ---- 3. task start brings it back with a new pid -----------------------
"$EXE" task start --name relay --data-dir "$D" > /dev/null 2>&1 ||
  fail "3: task start failed"
# a NEW running entry with a DIFFERENT pid (the old one stays stopped)
i=0
PID2=""
while [ "$i" -lt 150 ]; do
  PID2=$(runs | grep "task=relay	state=running" | grep -v "pid=$PID1" | head -1 |
    sed -E 's/.*pid=([0-9]+).*/\1/')
  [ -n "$PID2" ] && break
  sleep 0.1
  i=$((i + 1))
done
[ -n "$PID2" ] || { runs; cat "$WORK/r.err"; fail "3: the runner did not restart the task"; }
pass "3. task start → runner 对账重新起一个**新 pid** 的 running 条目（pid=${PID2}）"

kill -TERM "$RUNNER" 2>/dev/null
echo "E2E-P51-LIFECYCLE: $PASS passed, 0 failed"
