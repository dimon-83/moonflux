#!/bin/bash
# E2E-P47-POLL-RETRY: 长跑管道不会因为一次外部失败而死（决策 94）
#
# 起因是一个真实的便利性问题：源取数失败会让 `pipeline run` 直接退出 ✗，于是"让它一直跑"
# 变成别人的问题——部署里不得不靠 `systemd Restart=always` 兜着 ✓。而崩溃重启**不是重试**
# ✓（同一个失败只是多了一个进程边界 ✓）。这条门禁证明三件事：
#
#   1  取数连续失败时**进程不死**，每次尝试都打出来（1s、2s 退避 ✓），恢复后打一条"recovered" ✓
#   2  失败期过去后**数据照常流进来**（不是"重试了但什么都不做" ✓）
#   3  汇刷新失败**重试同一批**，批次不丢 ✓（对端最终收到且只收到一次 ✓）
#
# 另外一条"不假装"的腿：端点彻底不可达时进程**仍然活着**（没有崩溃循环 ✓），
# 只是持续按退避重试并如实报错 ✓。
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

EXE="${MOONFLUX_EXE:-$ROOT/_build/native/debug/build/apps/cli/cli.exe}"
WORK="$(mktemp -d /tmp/moonflux-p47.XXXXXX)"
PORT="${MOONFLUX_P47_PORT:-18611}"
SINK_PORT="${MOONFLUX_P47_SINK_PORT:-18612}"
PASS=0
SERVER_PID=""
SINK_PID=""

fail() {
  echo "E2E-P47-POLL-RETRY FAIL: $*" >&2
  [ -f "$WORK/run.err" ] && tail -4 "$WORK/run.err" >&2
  exit 1
}
pass() { echo "E2E-P47-POLL-RETRY PASS: $*"; PASS=$((PASS + 1)); }
cleanup() {
  [ -n "$SERVER_PID" ] && kill -9 "$SERVER_PID" 2>/dev/null
  [ -n "$SINK_PID" ] && kill -9 "$SINK_PID" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

[ -x "$EXE" ] || { echo "missing $EXE (build first)" >&2; exit 1; }
"$ROOT/scripts/build-operators.sh" > /dev/null 2>&1 || fail "could not build the operator modules"

cat > "$WORK/body.json" <<'JSON'
[{"node_name":"CN_进水COD","var_value":100,"ts":"2026-10-14T00:00:00Z","var_quality":192,"data_status":"正常"}]
JSON

# ---- 1/2. a source that is broken for the first two requests ------------
python3 "$ROOT/scripts/http_fixture_server.py" --port "$PORT" --body "$WORK/body.json" \
  --log "$WORK/requests.jsonl" --fail-first 2 > "$WORK/server.log" 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 60); do
  grep -q "fixture server on" "$WORK/server.log" 2>/dev/null && break
  sleep 0.1
done
cat > "$WORK/spec.json" <<JSON
{
  "apiVersion": "moonflux.io/v1alpha1",
  "kind": "Pipeline",
  "metadata": { "name": "p47-retry" },
  "spec": {
    "source": { "type": "http", "url": "http://127.0.0.1:$PORT/value", "interval_ms": 400 },
    "topic": { "name": "p47-polls" },
    "transforms": [
      { "type": "wasm",
        "module": "$ROOT/_build/wasm/debug/build/apps/operator-identity/operator-identity.wasm",
        "config": {} }
    ],
    "sink": { "type": "stdout" }
  }
}
JSON
"$EXE" pipeline run --data-dir "$WORK/d" --spec "$WORK/spec.json" \
  > "$WORK/run.out" 2> "$WORK/run.err" &
RUN=$!
sleep 6
kill -0 $RUN 2>/dev/null || { tail -4 "$WORK/run.err"; fail "1: the run died on a failed fetch"; }

grep -q "retrying in 1s (attempt 1)" "$WORK/run.err" ||
  { tail -4 "$WORK/run.err"; fail "1: the first retry was not reported with its backoff"; }
grep -q "retrying in 2s (attempt 2)" "$WORK/run.err" ||
  { tail -4 "$WORK/run.err"; fail "1: the backoff did not grow"; }
pass "1. 连续取数失败：进程不死，退避 1s→2s 且每次尝试都打出来"

[ -s "$WORK/run.out" ] || { tail -4 "$WORK/run.err"; fail "2: no data flowed after the failures passed"; }
grep -q "recovered after" "$WORK/run.err" ||
  { tail -4 "$WORK/run.err"; fail "2: the recovery was not reported"; }
pass "2. 失败期过去后数据照常流进来，并打出 recovered"

kill -9 $RUN 2>/dev/null
kill -9 $SERVER_PID 2>/dev/null
SERVER_PID=""

# ---- 3. a sink that fails its first POST: the batch is retried, not lost -
printf 'CN_进水COD\t{"node":"CN_进水COD","verdict":"STUCK","flat_minutes":160}\n' > "$WORK/one.txt"
python3 "$ROOT/scripts/http_fixture_server.py" --port "$SINK_PORT" \
  --body "$WORK/body.json" --log "$WORK/sink.log" --post-log "$WORK/sink-posts.txt" \
  --fail-first 1 > "$WORK/sink-server.log" 2>&1 &
SINK_PID=$!
for _ in $(seq 1 60); do
  grep -q "fixture server on" "$WORK/sink-server.log" 2>/dev/null && break
  sleep 0.1
done
cat > "$WORK/spec-sink.json" <<JSON
{
  "apiVersion": "moonflux.io/v1alpha1",
  "kind": "Pipeline",
  "metadata": { "name": "p47-sink" },
  "spec": {
    "source": { "type": "file", "path": "$WORK/one.txt" },
    "topic": { "name": "p47-sink-polls" },
    "transforms": [],
    "sink": { "type": "http", "url": "http://127.0.0.1:$SINK_PORT/hook",
              "headers": { "X-Test": "retry" } }
  }
}
JSON
# a file source is one-shot: the run finishes once the sink has finally
# accepted the batch, so "still alive after N seconds" is the WRONG assertion
# here (a finished run is not a dead one). Wait for it to finish, then check
# that it finished CLEANLY, retried, and delivered the batch exactly once.
"$EXE" pipeline run --data-dir "$WORK/d-sink" --spec "$WORK/spec-sink.json" \
  > "$WORK/sink.out" 2> "$WORK/sink.err" &
SINKRUN=$!
for _ in $(seq 1 60); do
  kill -0 $SINKRUN 2>/dev/null || break
  sleep 0.1
done
wait $SINKRUN
SINK_EXIT=$?
[ "$SINK_EXIT" = "0" ] || { tail -4 "$WORK/sink.err"; fail "3: the run did not finish cleanly (exit $SINK_EXIT)"; }
grep -q "sink http-post" "$WORK/sink.err" ||
  { tail -4 "$WORK/sink.err"; fail "3: the sink failure was not reported"; }
grep -q "recovered after" "$WORK/sink.err" ||
  { tail -4 "$WORK/sink.err"; fail "3: the sink recovery was not reported"; }
python3 - "$WORK/sink-posts.txt" <<'PY' || fail "3: the retried batch did not arrive exactly once"
import sys
body = open(sys.argv[1], encoding="utf-8").read()
lines = [l for l in body.splitlines() if l.strip()]
assert len(lines) == 1, f"expected the batch exactly once, got {len(lines)}: {body[:200]}"
assert '"verdict":"STUCK"' in lines[0], lines[0][:120]
PY
pass "3. 汇刷新失败：**重试同一批**，对端最终收到且只收到一次（批次不丢）"
kill -9 $SINKRUN 2>/dev/null
kill -9 $SINK_PID 2>/dev/null
SINK_PID=""

# ---- 4. a dead endpoint keeps the process alive (no crash loop) ---------
cat > "$WORK/spec-dead.json" <<JSON
{
  "apiVersion": "moonflux.io/v1alpha1",
  "kind": "Pipeline",
  "metadata": { "name": "p47-dead" },
  "spec": {
    "source": { "type": "http", "url": "http://127.0.0.1:18699/nothing", "interval_ms": 200 },
    "topic": { "name": "p47-dead-polls" },
    "transforms": [],
    "sink": { "type": "stdout" }
  }
}
JSON
"$EXE" pipeline run --data-dir "$WORK/d-dead" --spec "$WORK/spec-dead.json" \
  > "$WORK/dead.out" 2> "$WORK/dead.err" &
DEAD=$!
sleep 5
kill -0 $DEAD 2>/dev/null || { tail -4 "$WORK/dead.err"; fail "4: an unreachable endpoint killed the run"; }
grep -q "retrying in" "$WORK/dead.err" || { tail -4 "$WORK/dead.err"; fail "4: no retry was reported"; }
kill -9 $DEAD 2>/dev/null
pass "4. 端点彻底不可达：进程仍活着并按退避重试（不是崩溃循环）"

echo "E2E-P47-POLL-RETRY: $PASS passed, 0 failed"
