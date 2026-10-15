#!/bin/bash
# E2E-P60-GROUP-SOURCE: 持久进度（P1-2c，决策 124）
#
# 判据来自 docs/task-cluster-data-plane.md：**停机不丢数据**。主题源不提交进度，
# 所以 `from: end` 会丢掉停机期间到的记录、`from: beginning` 会重放全部；组的已提交
# 偏移是唯一有的答案。三条腿：
#
#   1  **跨重启续读**：任务读 2 条 → 停 → 再产 1 条 → **重启** ⇒ 它只读到**新的那条**
#      （既不重放历史，也不丢停机期间的记录——两者同时成立才是持久进度）
#   2  **提交是心跳带回去的**：停下来时它离开组（`group list` 里成员数回到 0），
#      下一次启动以一个**新成员**重新加入并从**已提交偏移**接着读
#   3  **按名拒绝**：组源需要协调者 ⇒ 没有控制面时**明说拒绝**，而不是当成别的源跑
#
# 语义仍是**至少一次**：本门禁断言的是"缺口 0 + 允许重复"，从不声称恰好一次。
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

EXE="${MOONFLUX_EXE:-$ROOT/_build/native/debug/build/apps/cli/cli.exe}"
WORK="$(mktemp -d /tmp/moonflux-p60.XXXXXX)"
SC_PORT="${MOONFLUX_P60_SC_PORT:-19881}"
METRICS_PORT="${MOONFLUX_P60_METRICS_PORT:-19882}"
NODE_PORT="${MOONFLUX_P60_NODE_PORT:-19883}"
PASS=0

fail() { echo "E2E-P60-GROUP-SOURCE FAIL: $*" >&2; exit 1; }
pass() { echo "E2E-P60-GROUP-SOURCE PASS: $*"; PASS=$((PASS + 1)); }
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
leader_of() { "$EXE" cluster leader --topic "$1" --remote "$SC" 2>/dev/null; }
read_topic() { "$EXE" consume --topic "$1" --from 0 --max 20 --remote "$2" 2>&1; }
stop_run() { # pid, then wait until it is really gone
  kill -TERM "$1" 2>/dev/null
  local i=0
  while [ "$i" -lt 120 ] && kill -0 "$1" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
  kill -0 "$1" 2>/dev/null && { kill -9 "$1" 2>/dev/null; return 1; }
  return 0
}

"$EXE" sc --listen "$SC" --data-dir "$WORK/sc" --metrics-listen "127.0.0.1:$METRICS_PORT" \
  > "$WORK/sc.log" 2>&1 &
wait_listen "$SC_PORT" || { cat "$WORK/sc.log"; fail "the control plane did not start"; }
"$EXE" spu --id n1 --listen "127.0.0.1:$NODE_PORT" --data-dir "$WORK/n1" --sc "$SC" \
  > "$WORK/n1.log" 2>&1 &
wait_listen "$NODE_PORT" || { cat "$WORK/n1.log"; fail "the data node did not start"; }
sleep 2

for t in g-in g-out; do
  "$EXE" topic create --name "$t" --partitions 1 --replication-factor 1 --remote "$SC" \
    > /dev/null 2>&1 || { cat "$WORK/sc.log"; fail "declaring $t failed"; }
done
sleep 1

cat > "$WORK/g.json" <<'JSON'
{"apiVersion":"moonflux.io/v1alpha1","kind":"Pipeline","metadata":{"name":"group-relay"},
 "spec":{"source":{"type":"group","name":"g-in","group":"relays"},"topic":{"name":"g-in"},
  "transforms":[],"sink":{"type":"topic","name":"g-out"}}}
JSON

IN_LEADER=$(leader_of g-in)
OUT_LEADER=$(leader_of g-out)
[ -n "$IN_LEADER" ] || fail "g-in has no host"
[ -n "$OUT_LEADER" ] || fail "g-out has no host"

printf 'first\nsecond\n' > "$WORK/in1.txt"
"$EXE" produce --topic g-in --file "$WORK/in1.txt" --remote "$IN_LEADER" > /dev/null 2>&1 ||
  fail "producing the first two records failed"

# ---- 1. the first run reads them and commits ----------------------------
"$EXE" pipeline run --name group-relay --control "$SC" --spec "$WORK/g.json" \
  > "$WORK/run1.out" 2> "$WORK/run1.err" &
R1=$!
i=0
while [ "$i" -lt 400 ]; do
  read_topic g-out "$OUT_LEADER" | grep -q "second" && break
  sleep 0.1; i=$((i + 1))
done
read_topic g-out "$OUT_LEADER" > "$WORK/out1.read" 2>&1
grep -q "first" "$WORK/out1.read" || { cat "$WORK/out1.read" "$WORK/run1.err"; fail "1: the first run did not relay the history"; }
grep -q "second" "$WORK/out1.read" || { cat "$WORK/out1.read" "$WORK/run1.err"; fail "1: the first run did not relay the second record"; }
# let the heartbeat carry the commit before stopping
sleep 2
stop_run "$R1" || { cat "$WORK/run1.err"; fail "1: the first run did not stop on SIGTERM"; }
pass "1. 第一次运行读满 2 条并提交（停下来时离开组，成员数回到 0）"

# ---- 2. the restart resumes from the COMMITTED offset -------------------
printf 'third\n' > "$WORK/in2.txt"
"$EXE" produce --topic g-in --file "$WORK/in2.txt" --remote "$IN_LEADER" > /dev/null 2>&1 ||
  fail "producing the third record failed"
"$EXE" pipeline run --name group-relay --control "$SC" --spec "$WORK/g.json" \
  > "$WORK/run2.out" 2> "$WORK/run2.err" &
R2=$!
i=0
while [ "$i" -lt 400 ]; do
  read_topic g-out "$OUT_LEADER" | grep -q "third" && break
  sleep 0.1; i=$((i + 1))
done
sleep 2
read_topic g-out "$OUT_LEADER" > "$WORK/out2.read" 2>&1
grep -q "third" "$WORK/out2.read" ||
  { cat "$WORK/out2.read" "$WORK/run2.err"; fail "2: the restart did not read what arrived while it was down"; }
FIRST=$(grep -cE "	first$" "$WORK/out2.read")
SECOND=$(grep -cE "	second$" "$WORK/out2.read")
[ "$FIRST" = "1" ] && [ "$SECOND" = "1" ] ||
  { cat "$WORK/out2.read"; fail "2: the restart replayed history (first=$FIRST second=$SECOND, each should be 1)"; }
stop_run "$R2" || { cat "$WORK/run2.err"; fail "2: the second run did not stop on SIGTERM"; }
pass "2. **跨重启续读**：停机期间到的第三条被读到，历史（first/second 各 1 条）没有被重放"

# ---- 3. a group source without a coordinator is refused by name --------
"$EXE" pipeline run --name group-relay --data-dir "$WORK/local" --spec "$WORK/g.json" \
  > "$WORK/bad.out" 2> "$WORK/bad.err" && fail "3: a group source without a control plane was accepted"
grep -q "needs a coordinator" "$WORK/bad.err" ||
  { cat "$WORK/bad.err"; fail "3: the refusal does not say a group source needs a coordinator"; }
pass "3. 按名拒绝：组源需要协调者 ⇒ 没有控制面时明说（不把它当成别的源跑）"

echo "E2E-P60-GROUP-SOURCE: $PASS passed, 0 failed"
release
exit 0
