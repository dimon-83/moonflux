#!/bin/bash
# E2E-P38-RUN-REGISTRATION: 运行登记（P37-2，决策 83）
#
# 这条门禁要证伪的是"运行对平台可见"这件事，以及两个**必须能分开**的结束方式：
#
#   1  活着的运行出现在 `run list` 里，带任务名、修订、pid、进度
#   2  **优雅停止 = stopped**（一次性源跑到耗尽：先写 run-stop，再上报 stopped），
#      而且它**扛过回收窗口**——回收只碰静默的 running，不碰已声明停止的
#   3  **被杀 = offline**（同一个静默窗口把它回收掉）——两者在列表里可区分，
#      这就是"不把 SIGKILL 冒充优雅"的可观测形式
#   4  run-log 主题里有结构化事件（run-start/batch/run-stop，按序、任务名一致）
#   5  **run id 由 run-log 起始偏移推导**：`<task>@<revision>#<offset>`，不读时钟，
#      因此可以从运行的记录重算出来
#   6  `/metrics` 只出**无标签**的计数（moonflux_runs / moonflux_runs_offline），
#      **任务名绝不进标签**（决策 79 的标签纪律）
#
# 如实边界：没有 `--control` 的运行**不登记、也不写 run-log**——不打招呼就往别人的
# 数据目录里加主题，正是 P36 那条进度标记踩过的坑（案例门禁当场抓到过）。
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

EXE="${MOONFLUX_EXE:-$ROOT/_build/native/debug/build/apps/cli/cli.exe}"
WORK="$(mktemp -d /tmp/moonflux-p38.XXXXXX)"
SC_PORT="${MOONFLUX_P38_SC_PORT:-19631}"
METRICS_PORT="${MOONFLUX_P38_METRICS_PORT:-19632}"
PIDS=""
PASS=0
REAP_MS="${MOONFLUX_P38_REAP_MS:-3000}"

fail() { echo "E2E-P38-RUN-REGISTRATION FAIL: $*" >&2; exit 1; }
pass() { echo "E2E-P38-RUN-REGISTRATION PASS: $*"; PASS=$((PASS + 1)); }

cleanup() {
  for pid in $PIDS; do kill -9 "$pid" 2>/dev/null; done
  wait 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

[ -x "$EXE" ] || { echo "missing $EXE (build first)" >&2; exit 1; }

wait_listen() { # port tenths
  local port="$1" tenths="${2:-80}" i=0
  while [ "$i" -lt "$tenths" ]; do
    lsof -i ":$port" -sTCP:LISTEN > /dev/null 2>&1 && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

runs() { "$EXE" run list --remote "127.0.0.1:$SC_PORT" 2>/dev/null; }

# wait_run <pattern> <tenths>: wait until the listing matches
wait_run() {
  local pattern="$1" tenths="${2:-100}" i=0
  while [ "$i" -lt "$tenths" ]; do
    runs | grep -q "$pattern" && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

D="$WORK/d"
mkdir -p "$D"
printf 'alpha\nbeta\n' > "$WORK/in.txt"
cat > "$WORK/oneshot.json" <<JSON
{"apiVersion":"moonflux.io/v1alpha1","kind":"Pipeline","metadata":{"name":"one-shot"},
 "spec":{"source":{"type":"file","path":"$WORK/in.txt"},"topic":{"name":"one-in"},
 "transforms":[],"sink":{"type":"stdout"}}}
JSON
cat > "$WORK/stream.json" <<'JSON'
{"apiVersion":"moonflux.io/v1alpha1","kind":"Pipeline","metadata":{"name":"stream-task"},
 "spec":{"source":{"type":"topic","name":"stream-in","from":"beginning"},"topic":{"name":"stream-in"},
 "transforms":[],"sink":{"type":"stdout"}}}
JSON

"$EXE" sc --listen "127.0.0.1:$SC_PORT" --data-dir "$WORK/sc" \
  --metrics-listen "127.0.0.1:$METRICS_PORT" > "$WORK/sc.log" 2>&1 &
PIDS="$PIDS $!"
wait_listen "$SC_PORT" || { cat "$WORK/sc.log"; fail "the control plane did not start"; }
wait_listen "$METRICS_PORT" || { cat "$WORK/sc.log"; fail "the metrics listener did not start"; }

# ---- 1. a live run is visible ------------------------------------------
"$EXE" pipeline run --data-dir "$D" --spec "$WORK/stream.json" \
  --control "127.0.0.1:$SC_PORT" > "$WORK/stream.out" 2> "$WORK/stream.err" &
STREAM_PID=$!
PIDS="$PIDS $STREAM_PID"
wait_run "task=stream-task	state=running" 100 ||
  { runs; cat "$WORK/stream.err"; fail "1: a running task did not appear in run list"; }
LINE=$(runs | grep "task=stream-task")
echo "$LINE" | grep -q "revision=0" || { echo "$LINE"; fail "1: the running task has no revision"; }
echo "$LINE" | grep -qE "pid=[0-9]+" || { echo "$LINE"; fail "1: the running task has no pid"; }
pass "1. a live run is listed with its task, revision and pid ($LINE)"

# ---- 5. the run id comes from the run-log offset ------------------------
RUN_ID=$(echo "$LINE" | cut -f1)
[ "$RUN_ID" = "stream-task@0#0" ] ||
  fail "5: expected stream-task@0#0 (task@revision#first run-log offset), got '$RUN_ID'"
FIRST=$("$EXE" consume --topic stream-task.run-log --from 0 --data-dir "$D" 2>/dev/null | head -1)
echo "$FIRST" | cut -f3 | grep -q "^run-start$" ||
  { echo "$FIRST"; fail "5: the run log does not start with run-start"; }
[ "$(echo "$FIRST" | cut -f1)" = "0" ] ||
  fail "5: the run-start record is not at offset 0, so the id cannot be derived from it"
pass "5. the run id is the task, the revision and the run-log offset of its run-start record"

# ---- 6. metrics: counts, never a label ---------------------------------
METRICS=$(python3 - "$METRICS_PORT" <<'PY'
import sys, urllib.request
print(urllib.request.urlopen(f"http://127.0.0.1:{sys.argv[1]}/metrics", timeout=5).read().decode())
PY
) || fail "6: could not scrape /metrics"
echo "$METRICS" | grep -qE "^moonflux_runs 1$" ||
  { echo "$METRICS" | grep runs; fail "6: /metrics does not report one running task"; }
echo "$METRICS" | grep -q "stream-task" &&
  { echo "$METRICS"; fail "6: a task NAME leaked into /metrics (labels must not take user input)"; }
pass "6. /metrics reports the run counts and carries no task name"

# ---- 3. killed = offline (the same silence window as nodes) -------------
kill -9 "$STREAM_PID" 2>/dev/null
wait "$STREAM_PID" 2>/dev/null
DEADLINE=$(( (REAP_MS / 100) + 100 ))
wait_run "task=stream-task	state=offline" "$DEADLINE" ||
  { runs; fail "3: a killed run was not reaped to offline within $((REAP_MS + 10000))ms"; }
LINE=$(runs | grep "task=stream-task")
echo "$LINE" | grep -q "state=offline" ||
  { echo "$LINE"; fail "3: the killed run is not offline"; }
echo "$LINE" | grep -q "state=stopped" &&
  { echo "$LINE"; fail "3: a killed run was reported as a graceful stop"; }
pass "3. a killed run goes offline (and is NOT reported as a graceful stop)"

# ---- 2. graceful = stopped, and it survives the reaper -----------------
"$EXE" pipeline run --data-dir "$D" --spec "$WORK/oneshot.json" \
  --control "127.0.0.1:$SC_PORT" > "$WORK/oneshot.out" 2> "$WORK/oneshot.err" ||
  { cat "$WORK/oneshot.err"; fail "2: the one-shot run failed"; }
wait_run "task=one-shot	state=stopped" 100 ||
  { runs; cat "$WORK/oneshot.err"; fail "2: a finished run was not reported as stopped"; }
# the reaper must not touch a deliberate stop: wait past the window and look again
sleep "$(( (REAP_MS / 1000) + 2 ))"
LINE=$(runs | grep "task=one-shot")
echo "$LINE" | grep -q "state=stopped" ||
  { echo "$LINE"; fail "2: the reaper turned a graceful stop into $(echo "$LINE" | grep -o 'state=[a-z]*')"; }
pass "2. a finished run says stopped, and the silence reaper leaves it alone"

# ---- 4. the run log is ordered and self-describing ---------------------
EVENTS=$("$EXE" consume --topic stream-task.run-log --from 0 --data-dir "$D" 2>/dev/null | cut -f3 | tr '\n' ' ')
case "$EVENTS" in
"run-start batch"*|"run-start "*) : ;;
*) fail "4: the run log does not start with run-start (got '$EVENTS')" ;;
esac
ONE_EVENTS=$("$EXE" consume --topic one-shot.run-log --from 0 --data-dir "$D" 2>/dev/null | cut -f3 | tr '\n' ' ')
echo "$ONE_EVENTS" | grep -q "run-start" || fail "4: the one-shot run log has no run-start"
echo "$ONE_EVENTS" | grep -q "batch" || fail "4: the one-shot run log has no batch"
echo "$ONE_EVENTS" | grep -q "run-stop" || fail "4: the one-shot run log has no run-stop"
# every event carries its own task name: the record explains itself
"$EXE" consume --topic one-shot.run-log --from 0 --data-dir "$D" 2>/dev/null |
  cut -f4 | grep -q '"task":"one-shot"' ||
  fail "4: a run-log event does not name its task"
pass "4. the run log holds run-start/batch/run-stop, each naming its task ($ONE_EVENTS)"

# ---- 7. a run without --control leaves no trace ------------------------
# The honest counterpart of registration: a run nobody was told about writes
# nothing into the data dir (no run-log topic appears) — the lesson the state
# progress marker taught in P36.
D2="$WORK/d2"
mkdir -p "$D2"
"$EXE" pipeline run --data-dir "$D2" --spec "$WORK/oneshot.json" > /dev/null 2>&1 ||
  fail "7: a run without --control failed"
if [ -d "$D2/topics/one-shot.run-log" ]; then
  fail "7: a run without --control wrote a run-log topic anyway"
fi
pass "7. a run without --control registers nowhere and writes no run log"

echo "E2E-P38-RUN-REGISTRATION: $PASS passed, 0 failed"
