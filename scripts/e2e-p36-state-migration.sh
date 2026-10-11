#!/bin/bash
# E2E-P36-STATE-MIGRATION: 有状态管道跨节点续算（P36，决策 77）
#
# 这是缺口"跨节点状态迁移/再均衡"的门禁。它断言的是**不重不漏**，不是"能启动"：
#
#   1  两条主题都 RF=2，两个数据节点各持一份副本
#   2  有状态管道在节点 A 上把前 4 条记录折算进状态（状态主题是唯一真相）
#   3  状态写回是**一次 append**：这一批的键与进度标记偏移连续（同一帧）
#   4  状态主题复制到 B（状态随之迁移，不是拷文件）
#   5  管道被杀（模拟进程/节点失效）后，在 B 上 `--resume` 只读**尚未折算**的输入
#   6  最终状态：8 个词各计 1 次——**重复计数会看到 2，缺口会少一个键**
#   7  三条按名拒绝：文件源 + --resume / 无状态主题 + --resume / 算子占用保留键
#   8  状态主题里没有标记时，`--resume` 如实说明"从头开始"（首次运行）
#
# 如实边界（写在 docs/state-migration.md，不藏在代码里）：`--resume` 的正确性
# 取决于**本节点状态副本的新鲜度**——落后于 leader 的副本带着更旧的标记，
# 会把已经折算过的记录再算一遍。门禁断言的是副本已收敛（hw==leo）的情形。
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

EXE="${MOONFLUX_EXE:-$ROOT/_build/native/debug/build/apps/cli/cli.exe}"
WORK="$(mktemp -d /tmp/moonflux-p36.XXXXXX)"
SC_PORT="${MOONFLUX_P36_SC_PORT:-19651}"
A_PORT="${MOONFLUX_P36_A_PORT:-19652}"
B_PORT="${MOONFLUX_P36_B_PORT:-19653}"
EVENTS="p36-events"
STATE="p36-state"
PIDS=""

fail() { echo "E2E-P36-STATE-MIGRATION FAIL: $*" >&2; exit 1; }
pass() { echo "E2E-P36-STATE-MIGRATION PASS: $*"; }

cleanup() {
  for pid in $PIDS; do
    kill "$pid" 2>/dev/null
  done
  wait 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

A_PID=""
B_PID=""
start_spu() { # id port dir
  "$EXE" spu --id "$1" --listen "127.0.0.1:$2" --data-dir "$3" \
    --sc "127.0.0.1:$SC_PORT" > "$3.log" 2>&1 &
  local pid=$!
  PIDS="$PIDS $pid"
  case "$1" in
  spu-a) A_PID="$pid" ;;
  spu-b) B_PID="$pid" ;;
  esac
}

wait_listen() { # port tenths
  local port="$1" tenths="${2:-80}" i=0
  while [ "$i" -lt "$tenths" ]; do
    lsof -i ":$port" -sTCP:LISTEN > /dev/null 2>&1 && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# run_until <spec> <out> <lines> <data-dir> [extra flags...]
run_until() {
  local spec="$1" out="$2" want="$3" dir="$4"
  shift 4
  "$EXE" pipeline run --data-dir "$dir" --spec "$spec" "$@" > "$out" 2> "$out.err" &
  local pid=$!
  PIDS="$PIDS $pid"
  local i=0
  while [ "$i" -lt 120 ]; do
    [ "$(wc -l < "$out" | tr -d ' ')" -ge "$want" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  sleep 0.4
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
}

[ -x "$EXE" ] || { echo "missing $EXE (build first)" >&2; exit 1; }
"$ROOT/scripts/build-operators.sh" > /dev/null 2>&1

# ---- cluster: one control plane, two data nodes --------------------------
mkdir -p "$WORK/sc"
"$EXE" sc --listen "127.0.0.1:$SC_PORT" --data-dir "$WORK/sc" > "$WORK/sc.log" 2>&1 &
PIDS="$PIDS $!"
wait_listen "$SC_PORT" || { cat "$WORK/sc.log"; fail "the control plane did not start"; }

for pair in "spu-a $A_PORT" "spu-b $B_PORT"; do
  set -- $pair
  start_spu "$1" "$2" "$WORK/$1"
done
wait_listen "$A_PORT" || { cat "$WORK/spu-a.log"; fail "spu-a did not start"; }
wait_listen "$B_PORT" || { cat "$WORK/spu-b.log"; fail "spu-b did not start"; }

# two replicas so both nodes hold the data AND the state: migration without a
# replica would be a copy, and this feature is about the log being the truth
for topic in "$EVENTS" "$STATE"; do
  "$EXE" topic create --name "$topic" --partitions 1 --replication-factor 2 \
    --remote "127.0.0.1:$SC_PORT" > /dev/null 2>&1 ||
    fail "could not declare $topic"
done

# both nodes need an applied pipeline naming the data topic (placement and the
# replication pull follow the applied topology, as in the P3/P7 gates)
for node in spu-a spu-b; do
  cat > "$WORK/apply-$node.json" <<JSON
{"apiVersion":"moonflux.io/v1alpha1","kind":"Pipeline","metadata":{"name":"p36"},
 "spec":{"source":{"type":"file","path":"$WORK/in.txt"},"transforms":[],
 "topic":{"name":"$EVENTS"},"sink":{"type":"stdout"}}}
JSON
  "$EXE" pipeline apply -f "$WORK/apply-$node.json" --data-dir "$WORK/$node" > /dev/null 2>&1 ||
    fail "pipeline apply failed on $node"
  # a node reads its topic at startup: restart it so the applied topology is
  # picked up (the P3 gates do the same, and it is the honest way to say
  # "applied before the run" rather than "applied eventually")
  if [ "$node" = "spu-a" ]; then
    kill "$A_PID" 2>/dev/null
    wait "$A_PID" 2>/dev/null
    start_spu spu-a "$A_PORT" "$WORK/spu-a"
    wait_listen "$A_PORT" || fail "$node did not restart"
  else
    kill "$B_PID" 2>/dev/null
    wait "$B_PID" 2>/dev/null
    start_spu spu-b "$B_PORT" "$WORK/spu-b"
    wait_listen "$B_PORT" || fail "$node did not restart"
  fi
done

leader_of() {
  "$EXE" cluster leader --topic "$EVENTS" --remote "127.0.0.1:$SC_PORT" 2>/dev/null || true
}
LEADER=""
for _ in $(seq 1 80); do
  LEADER="$(leader_of)"
  [ -n "$LEADER" ] && break
  sleep 0.25
done
[ -n "$LEADER" ] || { cat "$WORK/sc.log"; fail "1: no leader was placed for $EVENTS[0]"; }
A_ID=spu-a
A_DIR="$WORK/spu-a"
B_DIR="$WORK/spu-b"
if [ "$LEADER" = "127.0.0.1:$A_PORT" ]; then
  LEADER_ID=spu-a
else
  LEADER_ID=spu-b
fi
pass "1. $EVENTS[0] and $STATE[0] are declared RF=2; the leader is $LEADER_ID"

# the stateful pipeline: events -> key per word -> counter, state on a topic
cat > "$WORK/count.json" <<JSON
{"apiVersion":"moonflux.io/v1alpha1","kind":"Pipeline","metadata":{"name":"p36-count"},
 "spec":{"source":{"type":"topic","name":"$EVENTS","from":"beginning"},
 "topic":{"name":"$EVENTS"},
 "state":{"topic":"$STATE"},
 "transforms":[
   {"type":"wasm","module":"$ROOT/_build/wasm/debug/build/apps/operator-wordkeys/operator-wordkeys.wasm","config":{}},
   {"type":"wasm","module":"$ROOT/_build/wasm/debug/build/apps/operator-counter/operator-counter.wasm","config":{}}],
 "sink":{"type":"stdout"}}}
JSON

# ---- 2. the first half, folded in on node A ------------------------------
printf 'alpha\nbeta\ngamma\ndelta\n' > "$WORK/first.txt"
"$EXE" produce --topic "$EVENTS" --file "$WORK/first.txt" --remote "$LEADER" > /dev/null 2>&1 ||
  fail "2: produce failed"
# wait for the replica on A to carry all four (replication, not a copy)
for _ in $(seq 1 80); do
  [ "$("$EXE" consume --topic "$EVENTS" --remote "$LEADER" --from 0 2>/dev/null | wc -l | tr -d ' ')" -ge 4 ] && break
  sleep 0.25
done
run_until "$WORK/count.json" "$WORK/a.out" 4 "$A_DIR" --state-remote "127.0.0.1:$SC_PORT" --resume
[ "$(wc -l < "$WORK/a.out" | tr -d ' ')" -ge 4 ] ||
  { cat "$WORK/a.out.err"; cat "$WORK/a.out"; fail "2: the stateful pipeline on A did not process the first four records"; }
pass "2. node A folded four records into $STATE (and emitted four counted records)"

# ---- 3. one append per batch: the marker rides with the state ------------
"$EXE" consume --topic "$STATE" --from 0 --data-dir "$A_DIR" 2>/dev/null > "$WORK/state-a.txt"
KEY_LINES=$(grep -c -v "__moonflux_progress__" "$WORK/state-a.txt")
MARKER=$(grep "__moonflux_progress__" "$WORK/state-a.txt" | tail -1 | cut -f4)
[ "$KEY_LINES" = "4" ] || { cat "$WORK/state-a.txt"; fail "3: expected four keys and one marker, got $KEY_LINES keys"; }
[ "$MARKER" = "4" ] ||
  { cat "$WORK/state-a.txt"; fail "3: the progress marker should be 4 (four records absorbed), got '$MARKER'"; }
# the marker is the LAST entry of the batch's frame: its offset is the highest,
# and the whole batch is one contiguous run (that is what "one append" buys)
OFFSETS=$(cut -f1 "$WORK/state-a.txt" | sort -n | tr '\n' ' ' | sed 's/ *$//')
[ "$OFFSETS" = "0 1 2 3 4" ] ||
  { cat "$WORK/state-a.txt"; fail "3: expected one contiguous batch (offsets 0..4), got '$OFFSETS'"; }
pass "3. the batch's four keys and its progress marker are one contiguous append (offsets 0..4)"

# ---- 4. the state replicates to the other node --------------------------
for _ in $(seq 1 80); do
  REPLICA=$("$EXE" consume --topic "$STATE" --from 0 --data-dir "$B_DIR" 2>/dev/null | wc -l | tr -d ' ')
  [ "$REPLICA" -ge 5 ] && break
  sleep 0.25
done
[ "$REPLICA" -ge 5 ] ||
  { tail -5 "$WORK/spu-b.log"; fail "4: the state topic did not replicate to node B (saw $REPLICA entries)"; }
pass "4. the state topic replicated to node B ($REPLICA entries): the state moved as a log, not as a file"

# ---- 5. kill the pipeline, add the second half, resume on node B --------
pkill -f "pipeline run --data-dir $A_DIR" 2>/dev/null || true
sleep 0.3
printf 'epsilon\nzeta\neta\ntheta\n' > "$WORK/second.txt"
"$EXE" produce --topic "$EVENTS" --file "$WORK/second.txt" --remote "$LEADER" > /dev/null 2>&1 ||
  fail "5: the second produce failed"
for _ in $(seq 1 80); do
  [ "$("$EXE" consume --topic "$EVENTS" --remote "$LEADER" --from 0 2>/dev/null | wc -l | tr -d ' ')" -ge 8 ] && break
  sleep 0.25
done
run_until "$WORK/count.json" "$WORK/b.out" 4 "$B_DIR" --state-remote "127.0.0.1:$SC_PORT" --resume
grep -q "resuming at the offset the state recorded: 4" "$WORK/b.out.err" ||
  { cat "$WORK/b.out.err"; fail "5: node B did not resume from the recorded offset"; }
pass "5. node B resumed at offset 4 (the offset the state recorded) after the pipeline on A was killed"

# ---- 6. no double counting, no gap --------------------------------------
# the final state is read from the LEADER's copy: what the cluster agrees on
STATE_HOLDER="$LEADER_ID"
for _ in $(seq 1 80); do
  entries=$("$EXE" consume --topic "$STATE" --remote "$LEADER" --from 0 2>/dev/null | grep -c -v "__moonflux_progress__")
  [ "$entries" -ge 8 ] && break
  sleep 0.25
done
"$EXE" consume --topic "$STATE" --remote "$LEADER" --from 0 2>/dev/null |
  awk -F'\t' '$3 != "__moonflux_progress__" { seen[$3] = $4 } END { for (k in seen) print k"\t"seen[k] }' | sort > "$WORK/final.txt"
[ "$(wc -l < "$WORK/final.txt" | tr -d ' ')" = "8" ] ||
  { cat "$WORK/final.txt"; fail "6: expected eight words in the final state (a gap would show fewer)"; }
while read -r word count; do
  [ "$count" = "1" ] ||
    { cat "$WORK/final.txt"; fail "6: $word was counted $count times; the first four records were applied twice"; }
done < "$WORK/final.txt"
for word in alpha beta gamma delta epsilon zeta eta theta; do
  grep -q "^$word	1$" "$WORK/final.txt" || { cat "$WORK/final.txt"; fail "6: $word is missing from the final state"; }
done
pass "6. eight distinct words, each counted exactly once: the migration double-counted nothing and lost nothing"

# ---- 7. the three refusals ----------------------------------------------
# a file source carries no offsets, so --resume has nothing to continue from
python3 - "$WORK/count.json" "$WORK/file-source.json" "$WORK/first.txt" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
doc["spec"]["source"] = {"type": "file", "path": sys.argv[3]}
json.dump(doc, open(sys.argv[2], "w"))
PY
"$EXE" pipeline run --data-dir "$B_DIR" --spec "$WORK/file-source.json" --resume > /dev/null 2> "$WORK/r1.err"
grep -q "needs a topic source" "$WORK/r1.err" ||
  { cat "$WORK/r1.err"; fail "7: --resume with a file source was not refused by name"; }
python3 - "$WORK/count.json" "$WORK/no-state.json" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
del doc["spec"]["state"]
json.dump(doc, open(sys.argv[2], "w"))
PY
"$EXE" pipeline run --data-dir "$B_DIR" --spec "$WORK/no-state.json" --resume > /dev/null 2> "$WORK/r2.err"
grep -q "needs a state topic" "$WORK/r2.err" ||
  { cat "$WORK/r2.err"; fail "7: --resume without a state topic was not refused by name"; }
python3 - "$WORK/count.json" "$WORK/reserved.json" "$ROOT" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
doc["spec"]["state"] = {"topic": "p36-reserved-state"}
doc["spec"]["transforms"] = [
    {"type": "wasm", "module": sys.argv[3] + "/_build/wasm/debug/build/apps/operator-keyconst/operator-keyconst.wasm",
     "config": {"key": "__moonflux_progress__"}},
    {"type": "wasm", "module": sys.argv[3] + "/_build/wasm/debug/build/apps/operator-counter/operator-counter.wasm",
     "config": {}},
]
json.dump(doc, open(sys.argv[2], "w"))
PY
"$EXE" pipeline run --data-dir "$B_DIR" --spec "$WORK/reserved.json" > /dev/null 2> "$WORK/r3.err" &
RESERVED_PID=$!
PIDS="$PIDS $RESERVED_PID"
for _ in $(seq 1 40); do
  grep -q "reserves for its own progress" "$WORK/r3.err" && break
  sleep 0.1
done
kill "$RESERVED_PID" 2>/dev/null
grep -q "reserves for its own progress" "$WORK/r3.err" ||
  { cat "$WORK/r3.err"; fail "7: an operator using the reserved key was not refused by name"; }
pass "7. --resume without a topic source, without a state topic, and an operator claiming the reserved key are all refused by name"

# ---- 8. a state topic with no marker says so ----------------------------
"$EXE" topic create --name p36-fresh-state --partitions 1 --replication-factor 1 \
  --remote "127.0.0.1:$SC_PORT" > /dev/null 2>&1
python3 - "$WORK/count.json" "$WORK/fresh.json" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
doc["spec"]["state"] = {"topic": "p36-fresh-state"}
json.dump(doc, open(sys.argv[2], "w"))
PY
run_until "$WORK/fresh.json" "$WORK/c.out" 4 "$B_DIR" --state-remote "127.0.0.1:$SC_PORT" --resume
grep -q "holds no progress marker yet" "$WORK/c.out.err" ||
  { cat "$WORK/c.out.err"; fail "8: a first run with --resume did not say it is starting from the declared offset"; }
pass "8. with no marker in the state topic, --resume says so and starts at the declared offset"

echo "E2E-P36-STATE-MIGRATION: all green"
