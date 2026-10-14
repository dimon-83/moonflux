#!/bin/bash
# E2E-P50-SCHEDULING: 调度到指定节点（P37-5b 的放置半，决策 97）
#
# `target` 进任务集文档是"调度"的第一块：每个任务声明它该跑在哪个 worker（或 any）。
# runner 带 `--worker <id>` 时只跑 target 是它自己的任务——这是"一个控制面、多个 worker"
# 的地基；真正的控制面对账循环（desired vs actual、pending 可见、丢主人重分配）在它之上。
#
#   1  `pipeline list` 把每个任务的 target 显示出来（absent = any）
#   2  worker-a 的 runner 只跑 target=worker-a 的任务；target=worker-b 的**不跑**
#      （run list 里根本没有它的 running 条目——不是"跑了但报错"，是没被选中）
#   3  worker-b 的 runner 只跑 target=worker-b 的任务（对称）
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

EXE="${MOONFLUX_EXE:-$ROOT/_build/native/debug/build/apps/cli/cli.exe}"
WORK="$(mktemp -d /tmp/moonflux-p50.XXXXXX)"
SC_PORT="${MOONFLUX_P50_SC_PORT:-19681}"
METRICS_PORT="${MOONFLUX_P50_METRICS_PORT:-19682}"
PIDS=""
PASS=0

fail() { echo "E2E-P50-SCHEDULING FAIL: $*" >&2; exit 1; }
pass() { echo "E2E-P50-SCHEDULING PASS: $*"; PASS=$((PASS + 1)); }

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

cat > "$WORK/set.json" <<'JSON'
{"pipelines":[
 {"pipeline":"relay-a","target":"worker-a",
  "spec":{"apiVersion":"moonflux.io/v1alpha1","kind":"Pipeline","metadata":{"name":"relay-a"},
   "spec":{"source":{"type":"topic","name":"in-a","from":"beginning"},"topic":{"name":"in-a"},
    "transforms":[],"sink":{"type":"stdout"}}}},
 {"pipeline":"relay-b","target":"worker-b",
  "spec":{"apiVersion":"moonflux.io/v1alpha1","kind":"Pipeline","metadata":{"name":"relay-b"},
   "spec":{"source":{"type":"topic","name":"in-b","from":"beginning"},"topic":{"name":"in-b"},
    "transforms":[],"sink":{"type":"stdout"}}}}
]}
JSON

mkdir -p "$WORK/da" "$WORK/db"
"$EXE" pipeline apply -f "$WORK/set.json" --set --data-dir "$WORK/da" > /dev/null 2>&1 ||
  fail "apply of the set to data dir A failed"
"$EXE" pipeline apply -f "$WORK/set.json" --set --data-dir "$WORK/db" > /dev/null 2>&1 ||
  fail "apply of the set to data dir B failed"

# ---- 1. pipeline list shows each task's target -------------------------
LIST=$("$EXE" pipeline list --data-dir "$WORK/da" 2>/dev/null)
echo "$LIST" | grep -q "relay-a" || { echo "$LIST"; fail "1: relay-a is not listed"; }
echo "$LIST" | grep "relay-a" | grep -q "target=worker-a" ||
  { echo "$LIST"; fail "1: relay-a's target is not worker-a"; }
echo "$LIST" | grep "relay-b" | grep -q "target=worker-b" ||
  { echo "$LIST"; fail "1: relay-b's target is not worker-b"; }
pass "1. pipeline list 显示每个任务的 target（relay-a→worker-a，relay-b→worker-b）"

"$EXE" sc --listen "127.0.0.1:$SC_PORT" --data-dir "$WORK/sc" \
  --metrics-listen "127.0.0.1:$METRICS_PORT" > "$WORK/sc.log" 2>&1 &
PIDS="$PIDS $!"
wait_listen "$SC_PORT" || { cat "$WORK/sc.log"; fail "the control plane did not start"; }
export MOONFLUX_EXE="$EXE"

# ---- 2. worker-a runs only relay-a -------------------------------------
"$EXE" runner --data-dir "$WORK/da" --control "127.0.0.1:$SC_PORT" --worker worker-a \
  > "$WORK/ra.out" 2> "$WORK/ra.err" &
RA=$!
PIDS="$PIDS $RA"
wait_run "task=relay-a	state=running" 120 ||
  { runs; cat "$WORK/ra.err"; fail "2: worker-a did not run relay-a"; }
runs | grep -q "task=relay-b" &&
  { runs; fail "2: worker-a ran relay-b, which is pinned to worker-b"; }
pass "2. worker-a 只跑 relay-a（relay-b 不在 run list——不是报错，是没被选中）"
kill -TERM "$RA" 2>/dev/null
wait_run "task=relay-a	state=stopped" 120 || true
PIDS="$(echo "$PIDS" | tr ' ' '\n' | grep -v "^$RA$" | tr '\n' ' ')"

# ---- 3. worker-b runs only relay-b -------------------------------------
"$EXE" runner --data-dir "$WORK/db" --control "127.0.0.1:$SC_PORT" --worker worker-b \
  > "$WORK/rb.out" 2> "$WORK/rb.err" &
RB=$!
PIDS="$PIDS $RB"
wait_run "task=relay-b	state=running" 120 ||
  { runs; cat "$WORK/rb.err"; fail "3: worker-b did not run relay-b"; }
runs | grep "task=relay-a" | grep -q "state=running" &&
  { runs; fail "3: worker-b ran relay-a, which is pinned to worker-a"; }
pass "3. worker-b 只跑 relay-b（relay-a 没有 running 条目）"
kill -TERM "$RB" 2>/dev/null

echo "E2E-P50-SCHEDULING: $PASS passed, 0 failed"
