#!/bin/bash
# E2E-P54-DEPLOYMENT-PLANE: 部署并轨管理平面（P0-2，决策 112）
#
# 判据来自 docs/dev-plan.md 的 P0-2：把"每条管道一个 systemd 单元"换成
# `sc` + **一个** `moonflux runner`，并且**重启不重复副作用**。五条腿：
#
#   1  **一个 runner 管 ≥2 个任务**：两个任务的运行条目属于**同一个** worker，
#      而且机器上只有一个 runner 进程——这正是"单元数 = 1"的可执行形式
#   2  **重启后状态重放**：SIGTERM 之后两个任务都优雅停，再起时都回来
#   3  **重启不重复副作用**：源从 `end` 起的告警任务，重启 + 新记录 ⇒ 只多一次
#      投递（不是把历史重发一遍）——这是"不重复告警"的机制本身
#   4  **平台能看见那个陷阱**：`from: beginning` + 有外部副作用的 sink，
#      apply 期就被明说（内核 `replay_warnings`，决策 112）
#   5  **陷阱是真的**（反证腿）：同一个告警任务改成 `beginning`，重启后整段
#      历史被重发一遍——警告不是理论，是实测过的行为
#
# 门禁自己就是"工程外部署"的缩影：真 sc、真 runner、真 HTTP 对端、真重启。
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

EXE="${MOONFLUX_EXE:-$ROOT/_build/native/debug/build/apps/cli/cli.exe}"
WORK="$(mktemp -d /tmp/moonflux-p54.XXXXXX)"
SC_PORT="${MOONFLUX_P54_SC_PORT:-19751}"
METRICS_PORT="${MOONFLUX_P54_METRICS_PORT:-19752}"
HOOK_PORT="${MOONFLUX_P54_HOOK_PORT:-19753}"
PIDS=""
PASS=0

fail() { echo "E2E-P54-DEPLOYMENT-PLANE FAIL: $*" >&2; exit 1; }
pass() { echo "E2E-P54-DEPLOYMENT-PLANE PASS: $*"; PASS=$((PASS + 1)); }
cleanup() {
  # ONE scoped operation, and it is complete: every process this gate starts
  # carries this run's own temp path in its argv (`--data-dir $WORK/plant`,
  # `python3 $WORK/hook.py`), so a pattern scoped to that path kills exactly what
  # this gate started — including the runner's own `pipeline run` children, which
  # no pid list can follow.
  #
  # The pid list is deliberately NOT used. Measured here: `kill -TERM` on pids
  # collected with `$!` hit a RECYCLED pid on a busy machine, signalled an
  # unrelated process, and took the gate down inside its own cleanup (the log
  # showed the cleanup entered twice, the summary never printed, and the exit
  # status was 1). A cleanup that can signal the wrong process is worse than none.
  pkill -9 -f "$WORK" 2>/dev/null
  sleep 0.3
  # VERIFY the release and say so when it did not happen (iron rule 1): a
  # survivor keeps heartbeating a worker into the next run's control plane, which
  # makes a correct platform look stale.
  if pgrep -f "$WORK" > /dev/null 2>&1; then
    echo "WARNING: process(es) survived cleanup, still referencing $WORK:" >&2
    pgrep -fl "$WORK" >&2
  fi
  rm -rf "$WORK"
}

# The failure path releases and keeps the verdict...
trap 'status=$?; cleanup; exit "$status"' EXIT
# ...and the HAPPY path releases EXPLICITLY and disarms the trap, so the verdict
# cannot depend on what an EXIT trap does afterwards (measured: on CI's bash 5.x a
# failing command inside the trap turned a green gate's status into 1).
release() {
  cleanup
  trap - EXIT
}

[ -x "$EXE" ] || { echo "missing $EXE (build first)" >&2; exit 1; }
command -v python3 > /dev/null 2>&1 || fail "python3 is required for the webhook counter"

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
# how many RECORDS have left the process: the sink writes one line per value
runs() { "$EXE" run list --remote "$SC" 2>/dev/null; }
wait_run() {
  local pattern="$1" tenths="${2:-300}" i=0
  while [ "$i" -lt "$tenths" ]; do
    runs | grep -q "$pattern" && return 0
    sleep 0.1; i=$((i + 1))
  done
  return 1
}
hits() { grep -c '^v' "$WORK/hits.txt" 2>/dev/null | tr -d ' '; }
wait_hits() {
  local want="$1" tenths="${2:-200}" i=0
  while [ "$i" -lt "$tenths" ]; do
    [ "$(hits)" = "$want" ] && return 0
    sleep 0.1; i=$((i + 1))
  done
  return 1
}

# ---- the webhook endpoint: an independent python receiver ----------------
# Not our own client code: the point is to count what actually LEFT the process.
# The sink POSTs once per BATCH with the batch's values newline-delimited, so the
# honest unit is the RECORD, not the request (measured: two judgements arrive as
# one POST with a two-line body). A real webhook receiver has to cope with that,
# which is worth knowing before an alert channel formats it as one message.
cat > "$WORK/hook.py" <<'PY'
import http.server, sys
out = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n)
        with open(out, "ab") as f:
            f.write(body)
            if not body.endswith(b"\n"):
                f.write(b"\n")
        self.send_response(200)
        self.send_header("Content-Length", "2")
        self.end_headers()
        self.wfile.write(b"ok")
    def log_message(self, *a):
        pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[2])), H).serve_forever()
PY
: > "$WORK/hits.txt"
python3 "$WORK/hook.py" "$WORK/hits.txt" "$HOOK_PORT" > "$WORK/hook.log" 2>&1 &
PIDS="$PIDS $!"
wait_listen "$HOOK_PORT" || { cat "$WORK/hook.log"; fail "the webhook counter did not start"; }

# ---- the task set: TWO tasks, one control plane --------------------------
# judge : feed -> decisions (the judgement relay; no external effect)
# alert : decisions -> webhook (the side effect that must not repeat)
# Two DIFFERENT topics, because the platform refuses a topic owned by two tasks
# ("the read path picks the chain by topic"): the pair mirrors a real deployment,
# where one task produces the judgement topic and the next one acts on it.
# Both start at `end`: a restart resumes at the topic's end instead of
# re-delivering history. That single word is the difference between an alert and
# an alert storm, which is why the platform now says it out loud (leg 4).
alert_spec() {
  cat > "$WORK/alert-$1.json" <<JSON
{"apiVersion":"moonflux.io/v1alpha1","kind":"Pipeline","metadata":{"name":"alert"},
 "spec":{"source":{"type":"topic","name":"decisions","from":"$1"},
  "topic":{"name":"decisions"},"transforms":[],
  "sink":{"type":"http","url":"http://127.0.0.1:$HOOK_PORT/hook"}}}
JSON
}
alert_spec end
alert_spec beginning
cat > "$WORK/judge.json" <<'JSON'
{"apiVersion":"moonflux.io/v1alpha1","kind":"Pipeline","metadata":{"name":"judge"},
 "spec":{"source":{"type":"topic","name":"feed","from":"end"},"topic":{"name":"feed"},
  "transforms":[],"sink":{"type":"topic","name":"decisions"}}}
JSON
python3 - "$WORK/set.json" "$WORK/judge.json" "$WORK/alert-end.json" <<'PY'
import json, sys
out, judge, alert = sys.argv[1:4]
json.dump({"pipelines": [
    {"pipeline": "judge", "spec": json.load(open(judge))},
    {"pipeline": "alert", "spec": json.load(open(alert))},
]}, open(out, "w"))
PY

"$EXE" sc --listen "$SC" --data-dir "$WORK/sc" --metrics-listen "127.0.0.1:$METRICS_PORT" \
  > "$WORK/sc.log" 2>&1 &
PIDS="$PIDS $!"
wait_listen "$SC_PORT" || { cat "$WORK/sc.log"; fail "the control plane did not start"; }
export MOONFLUX_EXE="$EXE"

"$EXE" pipeline apply -f "$WORK/set.json" --set --remote "$SC" > "$WORK/apply.out" 2> "$WORK/apply.err" ||
  { cat "$WORK/apply.err"; fail "applying the task set failed"; }

# ---- ONE runner supervises BOTH tasks -----------------------------------
start_runner() {
  "$EXE" runner --data-dir "$WORK/plant" --control "$SC" --worker plant --restart on-failure \
    > "$WORK/runner-$1.out" 2> "$WORK/runner-$1.err" &
  RUNNER_PID=$!
  PIDS="$PIDS $RUNNER_PID"
}
start_runner first
wait_sched "judge	.*state=running" 400 || { sched; cat "$WORK/runner-first.err"; fail "2: judge did not start"; }
wait_sched "alert	.*state=running" 400 || { sched; cat "$WORK/runner-first.err"; fail "2: alert did not start"; }

RUNNERS=$(pgrep -f "runner --data-dir $WORK/plant" | wc -l | tr -d ' ')
[ "$RUNNERS" = "1" ] || fail "1: expected exactly one runner process, found $RUNNERS"
OWNERS=$(sched | grep -E "^(judge|alert)	" | sed -E 's/.*owner=([^	]*).*/\1/' | sort -u | tr '\n' ' ')
[ "$OWNERS" = "plant " ] ||
  { sched; fail "1: the two tasks are not supervised by the same worker (owners: $OWNERS)"; }
pass "1. **一个** runner（pid ${RUNNER_PID}）管着 judge 与 alert 两个任务（同一 worker=plant）"

# ---- it really delivers, and only what arrives --------------------------
# A topic source resolves `end` AT START, so the tasks must be up and settled
# before anything is produced: a record that lands first is simply not seen
# (the at-most-once side of starting at the end - measured, this leg failed on
# exactly that race before the settle).
sleep 1
printf 'v1\nv2\n' > "$WORK/in.txt"
"$EXE" produce --topic feed --file "$WORK/in.txt" --data-dir "$WORK/plant" > /dev/null 2>&1 ||
  fail "producing the judgements failed"
wait_hits 2 || { sched; cat "$WORK/runner-first.err"; fail "3: the webhook received $(hits) of 2 judgements"; }
pass "3a. 两个判决 → 恰好 2 条记录到达 webhook（每批一次 POST，报文一行一条）"

# ---- restart the runner: state replays, and NOTHING is re-sent ----------
kill -TERM "$RUNNER_PID" 2>/dev/null
# Wait for the PROCESS to be gone before asking about placement. Without this the
# assertions race the runner's own drain, and a still-heartbeating runner makes a
# correct platform look stale (measured: leg 2 failed here with a stale
# `owner=plant state=running` row while the runner was still up).
i=0
while [ "$i" -lt 100 ] && pgrep -f "runner --data-dir $WORK/plant" > /dev/null 2>&1; do
  sleep 0.1; i=$((i + 1))
done
pgrep -f "runner --data-dir $WORK/plant" > /dev/null 2>&1 &&
  { pgrep -fl "runner --data-dir $WORK/plant"; cat "$WORK/runner-first.err"; fail "2: the runner did not exit after SIGTERM"; }
# Two tables, two different facts, and the gate reads the right one for each:
#   run list  says HOW the run ended   -> stopped on purpose, not offline
#   schedule  says what SHOULD run now -> pending, with the reason (no live worker)
wait_run "task=judge	state=stopped" 200 ||
  { runs; cat "$WORK/runner-first.err"; fail "2: judge's run did not stop gracefully"; }
wait_run "task=alert	state=stopped" 200 ||
  { runs; cat "$WORK/runner-first.err"; fail "2: alert's run did not stop gracefully"; }
wait_sched "judge	.*state=pending" 200 ||
  { sched; fail "2: a task with no live worker is not shown as pending"; }
grep -q "no live worker" <<< "$(sched)" ||
  { sched; fail "2: pending does not carry its reason"; }
pass "2. runner 收 SIGTERM → 两个运行都**优雅停**（run list: stopped，不是 offline），且调度表如实显示 pending/no live worker"

start_runner second
wait_sched "alert	.*state=running" 400 || { sched; cat "$WORK/runner-second.err"; fail "2: alert did not come back"; }
# let both tasks resolve their `end` before a new record is produced: a topic
# source reads the end AT START, so a record that lands first is skipped (the
# honest at-most-once side of this trade)
sleep 1
[ "$(hits)" = "2" ] ||
  { sched; fail "3: the restart alone re-delivered (records=$(hits), expected 2)"; }
printf 'v3\n' > "$WORK/in.txt"
"$EXE" produce --topic feed --file "$WORK/in.txt" --data-dir "$WORK/plant" > /dev/null 2>&1 ||
  fail "producing after the restart failed"
wait_hits 3 || { sched; fail "3: a new judgement did not arrive (records=$(hits), expected 3)"; }
pass "3b. 重启后**只送新记录**：3 个判决 = 3 条记录到达（没有把历史重发）"

# ---- the platform names the trap at apply time --------------------------
set +e
"$EXE" pipeline apply -f "$WORK/alert-beginning.json" --data-dir "$WORK/plant" \
  > "$WORK/trap.out" 2> "$WORK/trap.err"
TRAP_STATUS=$?
set -e
[ "$TRAP_STATUS" = "0" ] || { cat "$WORK/trap.err"; fail "4: a replaying spec could not even be applied"; }
grep -q "EVERY restart re-delivers" "$WORK/trap.err" ||
  { cat "$WORK/trap.err"; fail "4: apply did not name the replay-into-side-effect trap"; }
grep -q "HTTP sink" "$WORK/trap.err" || { cat "$WORK/trap.err"; fail "4: the warning does not name the effect"; }
pass "4. apply 期就明说：from: beginning + 副作用 sink ⇒ **每次重启都会重发**（内核 replay_warnings）"

# ---- and the trap is real: prove it ------------------------------------
# Swap the alert task to the beginning variant and restart: the whole history
# (3 judgements) leaves the process again. This is the behaviour the warning is
# about, measured here rather than asserted in prose.
cat > "$WORK/begin-set.json" <<JSON
{"pipelines":[
 {"pipeline":"judge","spec":$(cat "$WORK/judge.json")},
 {"pipeline":"alert","spec":$(cat "$WORK/alert-beginning.json")}
]}
JSON
"$EXE" pipeline apply -f "$WORK/begin-set.json" --set --remote "$SC" > /dev/null 2>&1 ||
  fail "5: swapping the alert task failed"
kill -TERM "$RUNNER_PID" 2>/dev/null
wait_run "task=alert	state=stopped" 200 || { runs; fail "5: the alert task did not stop"; }
start_runner third
sleep 1
i=0
while [ "$i" -lt 300 ]; do
  [ "$(hits)" -ge 6 ] && break
  sleep 0.1; i=$((i + 1))
done
[ "$(hits)" -ge 6 ] ||
  { sched; fail "5: a beginning-sourced alert task did NOT replay its history (records=$(hits), expected >= 6)"; }
pass "5. 反证腿：同一个任务改成 beginning 后，重启把 3 条历史全部重发（records=$(hits)）——警告说的是真的"

release
echo "E2E-P54-DEPLOYMENT-PLANE: $PASS passed, 0 failed"
# `fail` is the only failing exit; reaching the last line means every leg passed
exit 0
