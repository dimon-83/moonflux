#!/bin/bash
# E2E-P59-CLUSTER-PIPELINE: 源进集群（P1-2b-ii，决策 122）
#
# 判据来自 docs/task-cluster-data-plane.md：一个任务**完全跑在集群主题上**。
# 三条腿：
#
#   1  **完整管道**：集群数据模式（--control 且不给 --data-dir）+ 集群 topic 源 + 集群 topic 汇
#      ⇒ 写进输入主题的记录，经过任务后出现在**输出主题**里（两端都由数据面宿主）
#   2  **`from: end` 不重放历史**：数据已存在之后再起一个 end 起的 run ⇒ 它**读不到旧记录**
#      （末端偏移来自服务端的水位，不是猜的）——这正是"重启不重复告警"的机制那一半
#   3  **没有宿主的源按名拒绝**：未声明的主题 ⇒ 明说 "no data node hosts it yet"，
#      而不是把"没人托管"读成"流是空的"
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

EXE="${MOONFLUX_EXE:-$ROOT/_build/native/debug/build/apps/cli/cli.exe}"
WORK="$(mktemp -d /tmp/moonflux-p59.XXXXXX)"
SC_PORT="${MOONFLUX_P59_SC_PORT:-19861}"
METRICS_PORT="${MOONFLUX_P59_METRICS_PORT:-19862}"
NODE_PORT="${MOONFLUX_P59_NODE_PORT:-19863}"
PASS=0

fail() { echo "E2E-P59-CLUSTER-PIPELINE FAIL: $*" >&2; exit 1; }
pass() { echo "E2E-P59-CLUSTER-PIPELINE PASS: $*"; PASS=$((PASS + 1)); }
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
read_topic() { "$EXE" consume --topic "$1" --from 0 --max 10 --remote "$2" 2>&1; }

"$EXE" sc --listen "$SC" --data-dir "$WORK/sc" --metrics-listen "127.0.0.1:$METRICS_PORT" \
  > "$WORK/sc.log" 2>&1 &
wait_listen "$SC_PORT" || { cat "$WORK/sc.log"; fail "the control plane did not start"; }
"$EXE" spu --id n1 --listen "127.0.0.1:$NODE_PORT" --data-dir "$WORK/n1" --sc "$SC" \
  > "$WORK/n1.log" 2>&1 &
wait_listen "$NODE_PORT" || { cat "$WORK/n1.log"; fail "the data node did not start"; }
sleep 2

for t in cd-in cd-out cd-out2; do
  "$EXE" topic create --name "$t" --partitions 1 --replication-factor 1 --remote "$SC" \
    > /dev/null 2>&1 || { cat "$WORK/sc.log"; fail "declaring $t failed"; }
done
sleep 1

cat > "$WORK/relay.json" <<'JSON'
{"apiVersion":"moonflux.io/v1alpha1","kind":"Pipeline","metadata":{"name":"cluster-relay"},
 "spec":{"source":{"type":"topic","name":"cd-in","from":"beginning"},"topic":{"name":"cd-in"},
  "transforms":[],"sink":{"type":"topic","name":"cd-out"}}}
JSON
# The end-starting run gets its OWN output topic: sharing one made "did it replay
# history?" a question about two writers, and an assertion that cannot tell its own
# records from someone else's is not an assertion.
cat > "$WORK/tail.json" <<'JSON'
{"apiVersion":"moonflux.io/v1alpha1","kind":"Pipeline","metadata":{"name":"cluster-tail"},
 "spec":{"source":{"type":"topic","name":"cd-in","from":"end"},"topic":{"name":"cd-in"},
  "transforms":[],"sink":{"type":"topic","name":"cd-out2"}}}
JSON

IN_LEADER=$(leader_of cd-in)
OUT_LEADER=$(leader_of cd-out)
OUT2_LEADER=$(leader_of cd-out2)
[ -n "$IN_LEADER" ] || fail "cd-in has no host"
[ -n "$OUT_LEADER" ] || fail "cd-out has no host"
[ -n "$OUT2_LEADER" ] || fail "cd-out2 has no host"

# data first, so a `from: end` run has something it must NOT replay
printf 'one\ntwo\n' > "$WORK/in.txt"
"$EXE" produce --topic cd-in --file "$WORK/in.txt" --remote "$IN_LEADER" > /dev/null 2>&1 ||
  fail "producing into the cluster topic failed"

# ---- 1. a pipeline that lives entirely on cluster topics ----------------
"$EXE" pipeline run --name cluster-relay --control "$SC" --spec "$WORK/relay.json" \
  > "$WORK/relay.out" 2> "$WORK/relay.err" &
RELAY=$!
i=0
while [ "$i" -lt 300 ]; do
  read_topic cd-out "$OUT_LEADER" | grep -q "one" && break
  sleep 0.1; i=$((i + 1))
done
read_topic cd-out "$OUT_LEADER" > "$WORK/out.read" 2>&1
grep -q "one" "$WORK/out.read" || { cat "$WORK/out.read" "$WORK/relay.err"; fail "1: the first record did not reach the output topic"; }
grep -q "two" "$WORK/out.read" || { cat "$WORK/out.read" "$WORK/relay.err"; fail "1: the second record did not reach the output topic"; }
kill -TERM "$RELAY" 2>/dev/null
i=0
while [ "$i" -lt 100 ] && kill -0 "$RELAY" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
kill -0 "$RELAY" 2>/dev/null && { kill -9 "$RELAY" 2>/dev/null; fail "1: the cluster-data run did not stop on SIGTERM"; }
pass "1. **完整集群数据管道**：写进 cd-in 的记录经任务出现在 cd-out（两端都由数据面宿主）"

# ---- 2. from: end does not replay what is already there ------------------
"$EXE" pipeline run --name cluster-tail --control "$SC" --spec "$WORK/tail.json" \
  > "$WORK/tail.out" 2> "$WORK/tail.err" &
TAIL=$!
sleep 3
printf 'three\n' > "$WORK/in2.txt"
"$EXE" produce --topic cd-in --file "$WORK/in2.txt" --remote "$IN_LEADER" > /dev/null 2>&1 ||
  fail "producing the third record failed"
i=0
while [ "$i" -lt 300 ]; do
  read_topic cd-out2 "$OUT2_LEADER" | grep -q "three" && break
  sleep 0.1; i=$((i + 1))
done
read_topic cd-out2 "$OUT2_LEADER" > "$WORK/out2.read" 2>&1
grep -q "three" "$WORK/out2.read" ||
  { cat "$WORK/out2.read" "$WORK/tail.err"; fail "2: the new record was not relayed"; }
# It started at the END, so its own output must hold EXACTLY the new record: not
# `one`, not `two`. Reading its own topic makes "no replay" a statement about this
# run rather than a count shared with the previous leg.
grep -qE "^(one|two)	" "$WORK/out2.read" &&
  { cat "$WORK/out2.read"; fail "2: the end-starting run replayed history"; }
COUNT=$(grep -c "^" "$WORK/out2.read")
[ "$COUNT" = "1" ] ||
  { cat "$WORK/out2.read"; fail "2: expected exactly the one new record, got $COUNT"; }
kill -TERM "$TAIL" 2>/dev/null
i=0
while [ "$i" -lt 100 ] && kill -0 "$TAIL" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
kill -0 "$TAIL" 2>/dev/null && kill -9 "$TAIL" 2>/dev/null
pass "2. `from: end` 不重放历史（末端偏移来自服务端水位；它自己的输出**恰好 1 条**且不含历史）"

# ---- 3. a source topic with no host is refused by name ------------------
cat > "$WORK/nohost.json" <<'JSON'
{"apiVersion":"moonflux.io/v1alpha1","kind":"Pipeline","metadata":{"name":"nohost"},
 "spec":{"source":{"type":"topic","name":"never-declared-in","from":"beginning"},"topic":{"name":"never-declared-in"},
  "transforms":[],"sink":{"type":"stdout"}}}
JSON
"$EXE" pipeline run --name nohost --control "$SC" --spec "$WORK/nohost.json" \
  > "$WORK/nohost.out" 2> "$WORK/nohost.err" && fail "3: a source topic with no host was accepted"
grep -q "no data node hosts it yet" "$WORK/nohost.err" ||
  { cat "$WORK/nohost.err"; fail "3: the failure does not say the source topic has no host"; }
pass "3. 没有宿主的源主题**按名拒绝**（不把「没人托管」读成「流是空的」）"

echo "E2E-P59-CLUSTER-PIPELINE: $PASS passed, 0 failed"
release
exit 0
