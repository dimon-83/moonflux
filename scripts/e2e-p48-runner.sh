#!/bin/bash
# E2E-P48-RUNNER: 常驻监督器 runner（P37-5a，决策 95）
#
# runner 是"kubelet"那一半：它不决定跑什么（任务集文档决定 ✓），只保证该跑的
# 任务**确实在跑**、按策略重启、并能在自己收到 SIGTERM 时让子进程优雅停下。
# 它自己不登记任何运行——每个子进程是普通 `pipeline run`，走 --control 登记、写
# run-log，所以 `run list` / `task logs` 看到的和以前是同一份事实。
#
#   1  起的任务出现在 run list（running，带 pid）
#   2  runner 收到 SIGTERM → 子进程优雅停止 → run list 变 stopped（不是 offline）
#   3  kill -9 子进程 → runner 按 on-failure 重启 → 新 pid 重新 running
#   4  --restart never → kill -9 子进程 → 不重启，任务停在 offline
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

EXE="${MOONFLUX_EXE:-$ROOT/_build/native/debug/build/apps/cli/cli.exe}"
WORK="$(mktemp -d /tmp/moonflux-p48.XXXXXX)"
SC_PORT="${MOONFLUX_P48_SC_PORT:-19641}"
METRICS_PORT="${MOONFLUX_P48_METRICS_PORT:-19642}"
PIDS=""
PASS=0
REAP_MS="${MOONFLUX_P48_REAP_MS:-3000}"

fail() { echo "E2E-P48-RUNNER FAIL: $*" >&2; exit 1; }
pass() { echo "E2E-P48-RUNNER PASS: $*"; PASS=$((PASS + 1)); }

cleanup() {
  # ONE scoped operation, and it is complete: every process this gate starts
  # carries its own temp path in its argv, so a pattern scoped to that path kills
  # exactly what it started — including the runner's `pipeline run` children,
  # which no pid list can follow.
  #
  # The pid list is deliberately NOT used. `kill -9` on pids collected earlier in
  # the run hits a RECYCLED pid once the original process is gone, and the victim
  # can be anything — measured elsewhere in this suite: a cleanup that signalled a
  # recycled pid took its own gate down mid-cleanup. On CI the victim looks like
  # "the runner has received a shutdown signal" (exit 143), which is exactly how
  # both the macOS and the Linux full jobs died right after p47 — the step before
  # this gate — twice in a row.
  [ -n "$WORK" ] || return 0
  pkill -9 -f "$WORK" 2>/dev/null
  sleep 0.3
  if pgrep -f "$WORK" > /dev/null 2>&1; then
    echo "WARNING: process(es) survived cleanup, still referencing $WORK:" >&2
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
task_pid() {
  runs | grep "task=$1	state=running" | head -1 | sed -E 's/.*pid=([0-9]+).*/\1/'
}

D="$WORK/d"
mkdir -p "$D"
cat > "$WORK/stream.json" <<'JSON'
{"apiVersion":"moonflux.io/v1alpha1","kind":"Pipeline","metadata":{"name":"relay"},
 "spec":{"source":{"type":"topic","name":"relay-in","from":"beginning"},"topic":{"name":"relay-in"},
 "transforms":[],"sink":{"type":"stdout"}}}
JSON
# A heartbeat at the top of each leg, on stdout, counted by the suite's step
# wrapper. Reason (decision 128): the full jobs died with exit 143 INSIDE this gate
# and the log held nothing between p47's PASS and the shutdown line, so "which leg
# was it in" was unanswerable. One bounded line per leg answers it next time.
# >&3 is the console (see gates.sh step()): this line survives a job that is killed
# from outside, which is the only way it was ever going to be read (decision 130).
echo "p48: leg 1 (local apply)" >&3
echo "p48: apply (local spec)" >&3
"$EXE" pipeline apply -f "$WORK/stream.json" --data-dir "$D" > /dev/null 2>&1 ||
  fail "apply of the relay task failed"

echo "p48: starting sc on $SC_PORT" >&3
"$EXE" sc --listen "127.0.0.1:$SC_PORT" --data-dir "$WORK/sc" \
  --metrics-listen "127.0.0.1:$METRICS_PORT" > "$WORK/sc.log" 2>&1 &
PIDS="$PIDS $!"
wait_listen "$SC_PORT" || { cat "$WORK/sc.log"; fail "the control plane did not start"; }

export MOONFLUX_EXE="$EXE"

echo "p48: leg 1/2/3. on-failure runner ------------------------------------------" >&3
# ---- 1/2/3. on-failure runner ------------------------------------------
echo "p48: starting runner" >&3
"$EXE" runner --data-dir "$D" --control "127.0.0.1:$SC_PORT" \
  > "$WORK/runner.out" 2> "$WORK/runner.err" &
RUNNER_PID=$!
PIDS="$PIDS $RUNNER_PID"
wait_run "task=relay	state=running" 120 ||
  { runs; cat "$WORK/runner.err"; fail "1: the runner did not start the task"; }
PID1=$(task_pid relay)
[ -n "$PID1" ] || { runs; fail "1: no pid for the running task"; }
pass "1. runner 起的任务进了 run list（running, pid=${PID1}）"

echo "p48: leg 3. kill -9 the child -> on-failure respawns -----------------------" >&3
# ---- 3. kill -9 the child -> on-failure respawns -----------------------
kill -9 "$PID1" 2>/dev/null
# the OLD run is still listed as "running" until the reap window turns it
# offline, so waiting for "running" matches the corpse; what proves a respawn is
# a running entry with a DIFFERENT pid
i=0
PID2=""
while [ "$i" -lt 150 ]; do
  PID2=$(runs | grep "task=relay	state=running" | grep -v "pid=$PID1" | head -1 |
    sed -E 's/.*pid=([0-9]+).*//')
  [ -n "$PID2" ] && break
  sleep 0.1
  i=$((i + 1))
done
[ -n "$PID2" ] ||
  { runs; cat "$WORK/runner.err"; fail "3: the runner did not restart the killed task"; }
pass "3. kill -9 子进程 → on-failure 重启（新 pid=${PID2}）"

echo "p48: leg 2. SIGTERM the runner -> graceful stop ----------------------------" >&3
# ---- 2. SIGTERM the runner -> graceful stop ----------------------------
kill -TERM "$RUNNER_PID" 2>/dev/null
wait_run "task=relay	state=stopped" 120 ||
  { runs; cat "$WORK/runner.err"; fail "2: the child did not stop gracefully"; }
pass "2. runner 收 SIGTERM → 子进程优雅停止（run list 变 stopped，不是 offline）"
PIDS="$(echo "$PIDS" | tr ' ' '\n' | grep -v "^$RUNNER_PID$" | tr '\n' ' ')"

echo "p48: leg 4. --restart never leaves a killed task offline -------------------" >&3
# ---- 4. --restart never leaves a killed task offline -------------------
"$EXE" runner --data-dir "$D" --control "127.0.0.1:$SC_PORT" --restart never \
  > "$WORK/runner2.out" 2> "$WORK/runner2.err" &
RUNNER2=$!
PIDS="$PIDS $RUNNER2"
# Take the child's pid from THIS runner's own report, not from "the first
# running line in the run list": that line can name an entry an earlier runner
# left behind, and killing the wrong process makes this leg lie (measured — the
# leg failed while the runner's own log said "left stopped (restart=never)").
i=0
PID3=""
while [ "$i" -lt 150 ]; do
  PID3=$(sed -n 's/.*started relay (pid \([0-9]*\)).*/\1/p' "$WORK/runner2.err" | tail -1)
  [ -n "$PID3" ] && break
  sleep 0.1
  i=$((i + 1))
done
[ -n "$PID3" ] ||
  { runs; cat "$WORK/runner2.err"; fail "4: the never-runner never announced a child"; }
wait_run "task=relay	state=running" 150 ||
  { runs; cat "$WORK/runner2.err"; fail "4: the never-runner's task is not running"; }
kill -9 "$PID3" 2>/dev/null
sleep "$((REAP_MS / 1000 + 1))"
runs | grep -q "task=relay	state=running" &&
  { runs; cat "$WORK/runner2.err"; fail "4: --restart never still restarted the killed task"; }
pass "4. --restart never：kill -9 后不重启，任务停在 offline"
kill -TERM "$RUNNER2" 2>/dev/null

echo "E2E-P48-RUNNER: $PASS passed, 0 failed"
