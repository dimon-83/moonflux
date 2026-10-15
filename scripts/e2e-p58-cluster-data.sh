#!/bin/bash
# E2E-P58-CLUSTER-DATA: 汇进集群（P1-2b-i，决策 121）
#
# 判据来自 docs/task-cluster-data-plane.md 的 P1-2b，第一片只做**汇**：
# 一个"集群数据模式"的运行（给了控制面、**没有** --data-dir）把结果发布到**数据面宿主**的
# 主题里。四条腿：
#
#   1  集群数据模式下，topic 汇的记录**落在集群主题里**（由数据节点宿主，可从 leader 读回）
#   2  **按名拒绝**：同一个模式 + **topic 源**（还没实现）⇒ 在任何注册之前**明说拒绝**，
#      绝不跑半个"能起但读不到东西"的管道
#   3  **反例腿**：`--data-dir` 口径不变（同样的 spec 带数据目录跑，汇仍写在本地主题里）
#   4  没有宿主的集群主题 ⇒ **结构化错误**（不是静默丢数据）
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

EXE="${MOONFLUX_EXE:-$ROOT/_build/native/debug/build/apps/cli/cli.exe}"
WORK="$(mktemp -d /tmp/moonflux-p58.XXXXXX)"
SC_PORT="${MOONFLUX_P58_SC_PORT:-19841}"
METRICS_PORT="${MOONFLUX_P58_METRICS_PORT:-19842}"
NODE_PORT="${MOONFLUX_P58_NODE_PORT:-19843}"
PASS=0

fail() { echo "E2E-P58-CLUSTER-DATA FAIL: $*" >&2; exit 1; }
pass() { echo "E2E-P58-CLUSTER-DATA PASS: $*"; PASS=$((PASS + 1)); }
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

"$EXE" sc --listen "$SC" --data-dir "$WORK/sc" --metrics-listen "127.0.0.1:$METRICS_PORT" \
  > "$WORK/sc.log" 2>&1 &
wait_listen "$SC_PORT" || { cat "$WORK/sc.log"; fail "the control plane did not start"; }
"$EXE" spu --id n1 --listen "127.0.0.1:$NODE_PORT" --data-dir "$WORK/n1" --sc "$SC" \
  > "$WORK/n1.log" 2>&1 &
wait_listen "$NODE_PORT" || { cat "$WORK/n1.log"; fail "the data node did not start"; }
sleep 2

# the output topic is a cluster topic: declare it (declaration stays an operator
# action - decision 118's boundary)
"$EXE" topic create --name out-q --partitions 1 --replication-factor 1 --remote "$SC" \
  > /dev/null 2>&1 || { cat "$WORK/sc.log"; fail "declaring out-q failed"; }
sleep 1

printf 'alpha\nbeta\n' > "$WORK/in.txt"
cat > "$WORK/sink.json" <<JSON
{"apiVersion":"moonflux.io/v1alpha1","kind":"Pipeline","metadata":{"name":"publisher"},
 "spec":{"source":{"type":"file","path":"$WORK/in.txt"},"topic":{"name":"publisher-in"},
  "transforms":[],"sink":{"type":"topic","name":"out-q"}}}
JSON

# ---- 1. cluster-data mode: the sink IS the cluster ----------------------
"$EXE" pipeline run --name publisher --control "$SC" --spec "$WORK/sink.json" \
  > "$WORK/run.out" 2> "$WORK/run.err" || { cat "$WORK/run.err"; fail "1: the cluster-data run failed"; }
LEADER=$(leader_of out-q)
[ -n "$LEADER" ] || fail "1: out-q has no host"
"$EXE" consume --topic out-q --from 0 --max 10 --remote "$LEADER" > "$WORK/on-cluster" 2>&1 ||
  { cat "$WORK/on-cluster"; fail "1: reading out-q from its host failed"; }
grep -q "alpha" "$WORK/on-cluster" || { cat "$WORK/on-cluster"; fail "1: alpha did not reach the cluster"; }
grep -q "beta" "$WORK/on-cluster" || { cat "$WORK/on-cluster"; fail "1: beta did not reach the cluster"; }
pass "1. 集群数据模式：topic 汇的记录**落在集群主题**里（宿主 = ${LEADER}）"

# ---- 2. the unimplemented half refuses BY NAME --------------------------
cat > "$WORK/source.json" <<'JSON'
{"apiVersion":"moonflux.io/v1alpha1","kind":"Pipeline","metadata":{"name":"reader"},
 "spec":{"source":{"type":"topic","name":"out-q","from":"beginning"},"topic":{"name":"out-q"},
  "transforms":[],"sink":{"type":"stdout"}}}
JSON
"$EXE" pipeline run --name reader --control "$SC" --spec "$WORK/source.json" \
  > "$WORK/bad.out" 2> "$WORK/bad.err" && fail "2: a cluster topic source was accepted"
grep -q "cluster topic SOURCE is not implemented" "$WORK/bad.err" ||
  { cat "$WORK/bad.err"; fail "2: the refusal does not name the missing half"; }
pass "2. 按名拒绝：集群数据模式 + topic 源 ⇒ **明说还没实现**（不跑半个读不到东西的管道）"

# ---- 3. the --data-dir route is unchanged -------------------------------
"$EXE" pipeline run --data-dir "$WORK/local" --spec "$WORK/sink.json" \
  > "$WORK/local.out" 2> "$WORK/local.err" || { cat "$WORK/local.err"; fail "3: the local run failed"; }
"$EXE" consume --topic out-q --from 0 --max 10 --data-dir "$WORK/local" > "$WORK/on-local" 2>&1 ||
  { cat "$WORK/on-local"; fail "3: reading the local out-q failed"; }
grep -q "alpha" "$WORK/on-local" || { cat "$WORK/on-local"; fail "3: the local sink wrote nothing"; }
pass "3. 反例腿：`--data-dir` 口径不变（同样的 spec 带数据目录跑，汇写在本地主题里）"

# ---- 4. no host: the error is SAID, and a stop is still a stop ----------
# The platform retries a failing sink FOREVER on purpose ("a sink that drops a
# batch on the first error is a sink that silently loses alerts"), so this leg
# does not expect the run to fail. What it does expect: the error is reported by
# name, and the retry loop still notices a stop request — otherwise `task stop`
# would have to be a SIGKILL, and the run would end `offline` instead of
# `stopped`, which is the distinction P37-2 exists to keep.
sed 's/out-q/never-declared-q/' "$WORK/sink.json" > "$WORK/nohost.json"
"$EXE" pipeline run --name publisher --control "$SC" --spec "$WORK/nohost.json" \
  > "$WORK/nohost.out" 2> "$WORK/nohost.err" &
STUCK=$!
i=0
while [ "$i" -lt 200 ]; do
  grep -qE "no leader|has no host" "$WORK/nohost.err" && break
  sleep 0.1; i=$((i + 1))
done
grep -qE "no leader|has no host" "$WORK/nohost.err" ||
  { cat "$WORK/nohost.err"; kill -9 "$STUCK" 2>/dev/null; fail "4: the failing sink was not reported by name"; }
kill -TERM "$STUCK" 2>/dev/null
i=0
while [ "$i" -lt 100 ] && kill -0 "$STUCK" 2>/dev/null; do
  sleep 0.1; i=$((i + 1))
done
if kill -0 "$STUCK" 2>/dev/null; then
  kill -9 "$STUCK" 2>/dev/null
  fail "4: a run stuck on a dead sink could not be stopped gracefully (the retry loop ignores the signal)"
fi
pass "4. 没有宿主的主题：错误**按名说出** ✓，且**停止信号仍被响应**（重试循环不是不可优雅停止的）"

echo "E2E-P58-CLUSTER-DATA: $PASS passed, 0 failed"
release
exit 0
