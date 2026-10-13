#!/bin/bash
# E2E-P37-MULTI-TASK: 多任务地基（P37-1，决策 79/81）
#
# 这是"任务管理"的平台侧地基。要证伪的不是"能存两个 spec"，而是这四件事：
#
#   1  一个数据目录持**多个任务**，`pipeline list` 如实列出
#   2  **取数按 topic 选链**：同一进程里，pa 走上变换、pb 走另一条、pc（无任务）
#      原样通过——三条不同路径，这是"一个主题属于一个任务"的可观测后果
#   3  冲突**按名拒绝**且说清是谁：同主题、重名、未知删除名、run 歧义
#   4  **失败不写盘**：任何一次被拒的 apply 之后，集合与之前逐字节一致
#
# 还钉住两条与既有决策相连的纪律：
#   * `/metrics` 里**不得出现任务名**（标签不接受用户输入，决策 79）
#   * 旧 v1 文档（单任务）**内存迁移**，且 upsert 之后兄弟任务的存储 JSON
#     逐字段保留（升级不能把别人的 applied_at/functions 抹掉）
#
# 注意（如实边界）：本地 apply **丢弃** `cluster_revision`——那不是集群的文档，
# 集群托管的节点会在下一次拉取时重新采纳控制面的集合。集群侧的 upsert/delete
# 与节点采纳是 P37-1b，本门禁只覆盖本地口径。
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

EXE="${MOONFLUX_EXE:-$ROOT/_build/native/debug/build/apps/cli/cli.exe}"
WORK="$(mktemp -d /tmp/moonflux-p37.XXXXXX)"
PORT="${MOONFLUX_P37_PORT:-19661}"
METRICS_PORT="${MOONFLUX_P37_METRICS_PORT:-19662}"
PIDS=""
PASS=0

fail() { echo "E2E-P37-MULTI-TASK FAIL: $*" >&2; exit 1; }
pass() { echo "E2E-P37-MULTI-TASK PASS: $*"; PASS=$((PASS + 1)); }

cleanup() {
  for pid in $PIDS; do kill "$pid" 2>/dev/null; done
  wait 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

[ -x "$EXE" ] || { echo "missing $EXE (build first)" >&2; exit 1; }
"$ROOT/scripts/build-operators.sh" > /dev/null 2>&1
UPPER="$ROOT/_build/wasm/debug/build/apps/operator-upper/operator-upper.wasm"
[ -f "$UPPER" ] || fail "operator-upper.wasm is missing (build-operators.sh)"

wait_listen() { # port tenths
  local port="$1" tenths="${2:-80}" i=0
  while [ "$i" -lt "$tenths" ]; do
    lsof -i ":$port" -sTCP:LISTEN > /dev/null 2>&1 && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

D="$WORK/d"
mkdir -p "$D"

# fixtures are generated, not hand written: a "bare spec" in a --set document is
# a whole PipelineSpec document, and a stored task object's "spec" is that same
# whole document (three test runs in a row died on getting this wrong by hand)
python3 - "$WORK" "$UPPER" <<'PY'
import json, sys, pathlib
work, upper = pathlib.Path(sys.argv[1]), sys.argv[2]

def spec(name, topic, transforms):
    return {
        "apiVersion": "moonflux.io/v1alpha1",
        "kind": "Pipeline",
        "metadata": {"name": name},
        "spec": {
            "source": {"type": "topic", "name": topic, "from": "beginning"},
            "topic": {"name": topic},
            "transforms": transforms,
            "sink": {"type": "topic", "name": f"out-{name}"},
        },
    }

upper_t = [{"type": "wasm", "module": upper, "config": {}}]
a = spec("task-a", "pa", upper_t)
b = spec("task-b", "pb", [])
c = spec("task-c", "pa", [])          # collides with task-a on purpose
(work / "task-a.json").write_text(json.dumps(a, indent=2))
(work / "task-b.json").write_text(json.dumps(b, indent=2))
(work / "task-c.json").write_text(json.dumps(c, indent=2))
(work / "set-bare.json").write_text(json.dumps({"pipelines": [a, b]}, indent=2))
(work / "set-dup.json").write_text(json.dumps({"pipelines": [a, a]}, indent=2))
(work / "set-conflict.json").write_text(json.dumps({"pipelines": [a, c]}, indent=2))
# a changed task-a: same name, same topic, different transform
a2 = spec("task-a", "pa", [])
(work / "task-a2.json").write_text(json.dumps(a2, indent=2))
PY

# ---- 1. two tasks in one data dir ---------------------------------------
"$EXE" pipeline apply -f "$WORK/task-a.json" --data-dir "$D" > /dev/null 2>&1 ||
  fail "1: applying task-a failed"
"$EXE" pipeline apply -f "$WORK/task-b.json" --data-dir "$D" > /dev/null 2>&1 ||
  fail "1: applying task-b failed"
LIST=$("$EXE" pipeline list --data-dir "$D" 2>&1)
echo "$LIST" | grep -q "^task-a	topic=pa	transforms=1" ||
  { echo "$LIST"; fail "1: task-a is not listed as topic pa with one transform"; }
echo "$LIST" | grep -q "^task-b	topic=pb	transforms=0" ||
  { echo "$LIST"; fail "1: task-b is not listed as topic pb with no transforms"; }
pass "1. two tasks live in one data dir and are listed with their topics and transforms"

# ---- 2. the read path picks the chain BY TOPIC --------------------------
"$EXE" serve --data-dir "$D" --listen "127.0.0.1:$PORT" \
  --metrics-listen "127.0.0.1:$METRICS_PORT" > "$WORK/serve.log" 2>&1 &
PIDS="$PIDS $!"
wait_listen "$PORT" || { cat "$WORK/serve.log"; fail "2: serve did not start"; }
wait_listen "$METRICS_PORT" || { cat "$WORK/serve.log"; fail "2: the metrics listener did not start"; }

printf 'alpha\n' > "$WORK/pa.txt"
printf 'beta\n' > "$WORK/pb.txt"
printf 'gamma\n' > "$WORK/pc.txt"
for t in pa pb pc; do
  "$EXE" produce --topic "$t" --file "$WORK/$t.txt" --remote "127.0.0.1:$PORT" > /dev/null 2>&1 ||
    fail "2: producing to $t failed"
done
PA=$("$EXE" consume --topic pa --from 0 --remote "127.0.0.1:$PORT" 2>/dev/null | cut -f4 | tr -d '\n')
PB=$("$EXE" consume --topic pb --from 0 --remote "127.0.0.1:$PORT" 2>/dev/null | cut -f4 | tr -d '\n')
PC=$("$EXE" consume --topic pc --from 0 --remote "127.0.0.1:$PORT" 2>/dev/null | cut -f4 | tr -d '\n')
# the rule set loads on the READ path (sync runs when a fetch arrives), so the
# assertion belongs after the reads — asking before them would be asserting a
# log line the server has no reason to have printed yet
grep -q "rules active: 2 task(s) (task-a, task-b)" "$WORK/serve.log" ||
  { cat "$WORK/serve.log"; fail "2: serve did not report the two-task rule set"; }
[ "$PA" = "ALPHA" ] || fail "2: pa should be transformed by task-a (upper), got '$PA'"
[ "$PB" = "beta" ] || fail "2: pb belongs to task-b, which has no transforms, got '$PB'"
[ "$PC" = "gamma" ] || fail "2: pc has no task at all and must pass through, got '$PC'"
pass "2. the chain is picked by topic: pa->ALPHA (task-a), pb->beta (task-b), pc->gamma (no task)"

# ---- 3. metrics: a count, never a label ---------------------------------
METRICS=$(python3 - "$METRICS_PORT" <<'PY'
import sys, urllib.request
print(urllib.request.urlopen(f"http://127.0.0.1:{sys.argv[1]}/metrics", timeout=5).read().decode())
PY
) || fail "3: could not scrape /metrics"
echo "$METRICS" | grep -q "^moonflux_tasks 2$" ||
  { echo "$METRICS"; fail "3: /metrics does not report two tasks"; }
echo "$METRICS" | grep -q "task-a" &&
  { echo "$METRICS"; fail "3: a task NAME leaked into /metrics (labels must not take user input)"; }
pass "3. /metrics reports the task count and carries no task name (labels stay un-tainted)"

# ---- 4. a topic belongs to exactly one task -----------------------------
OUT=$("$EXE" pipeline apply -f "$WORK/task-c.json" --data-dir "$D" 2>&1)
echo "$OUT" | grep -q "tasks task-a and task-c both declare topic pa" ||
  { echo "$OUT"; fail "4: a topic collision was not refused by name"; }
pass "4. two tasks claiming one topic are refused by name, naming both"

# ---- 5/6. upsert preserves the siblings, byte for byte ------------------
python3 - "$D/topology.json" "$WORK/before.json" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
sibling = [t for t in doc["pipelines"] if t["pipeline"] == "task-b"][0]
json.dump(sibling, open(sys.argv[2], "w"), sort_keys=True)
PY
"$EXE" pipeline apply -f "$WORK/task-a2.json" --data-dir "$D" > /dev/null 2>&1 ||
  fail "5: re-applying task-a failed"
python3 - "$D/topology.json" "$WORK/before.json" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
sibling = [t for t in doc["pipelines"] if t["pipeline"] == "task-b"][0]
before = json.load(open(sys.argv[2]))
if json.dumps(sibling, sort_keys=True) != json.dumps(before, sort_keys=True):
    print("sibling changed:", json.dumps(before), "->", json.dumps(sibling), file=sys.stderr)
    sys.exit(1)
transforms = len([t for t in doc["pipelines"] if t["pipeline"] == "task-a"][0]["spec"]["spec"]["transforms"])
if transforms != 0:
    print(f"task-a still has {transforms} transforms after the update", file=sys.stderr)
    sys.exit(1)
PY
[ $? -eq 0 ] || fail "5: upsert did not preserve the sibling task verbatim"
pass "5. an upsert replaces only its own task; the sibling's stored JSON is untouched"

# ---- 7. delete ----------------------------------------------------------
"$EXE" pipeline delete --name task-a --data-dir "$D" > /dev/null 2>&1 ||
  fail "7: deleting an existing task failed"
"$EXE" pipeline list --data-dir "$D" | grep -q "^task-a" &&
  fail "7: task-a is still listed after delete"
OUT=$("$EXE" pipeline delete --name nope --data-dir "$D" 2>&1)
echo "$OUT" | grep -q "no task named nope under .* (tasks: task-b)" ||
  { echo "$OUT"; fail "7: deleting an unknown name did not refuse and name what exists"; }
pass "7. delete removes one task, and an unknown name is refused while naming the known ones"

# ---- 8/9/10. --set: replace, duplicate names, topic conflict ------------
"$EXE" pipeline apply --set -f "$WORK/set-bare.json" --data-dir "$D" > /dev/null 2>&1 ||
  fail "8: --set with two bare specs failed"
NAMES=$("$EXE" pipeline list --data-dir "$D" | cut -f1 | tr '\n' ' ' | sed 's/ $//')
[ "$NAMES" = "task-a task-b" ] ||
  { fail "8: --set should hold exactly task-a and task-b, got '$NAMES'"; }
OUT=$("$EXE" pipeline apply --set -f "$WORK/set-dup.json" --data-dir "$D" 2>&1)
echo "$OUT" | grep -q "two tasks are named task-a" ||
  { echo "$OUT"; fail "9: a --set with duplicate names was not refused by name"; }
OUT=$("$EXE" pipeline apply --set -f "$WORK/set-conflict.json" --data-dir "$D" 2>&1)
echo "$OUT" | grep -q "both declare topic pa" ||
  { echo "$OUT"; fail "10: a --set with a topic collision was not refused by name"; }
pass "8. --set replaces the whole set, and both refusals (duplicate name, colliding topic) fire by name"

# ---- 11. a refused apply writes nothing ---------------------------------
AFTER=$("$EXE" pipeline list --data-dir "$D" | cut -f1 | tr '\n' ' ' | sed 's/ $//')
[ "$AFTER" = "task-a task-b" ] ||
  fail "11: a refused apply changed the set ('$AFTER')"
pass "11. every refused apply left the stored set exactly as it was"

# ---- 12. a legacy v1 document migrates, and stays intact across a write -
D2="$WORK/legacy"
mkdir -p "$D2"
"$EXE" pipeline apply -f "$WORK/task-a.json" --data-dir "$D2" > /dev/null 2>&1 ||
  fail "12: could not seed the legacy data dir"
python3 - "$D2/topology.json" <<'PY'
import json, sys
path = sys.argv[1]
doc = json.load(open(path))
task = doc["pipelines"][0]
# the shape the previous version wrote: one pipeline at the top level
legacy = {
    "pipeline": task["pipeline"],
    "applied_at": task["applied_at"],
    "functions": [{"name": "legacy-set", "revision": 3}],
    "spec": task["spec"],
    "cluster_revision": 9,
}
json.dump(legacy, open(path, "w"), indent=2)
PY
"$EXE" pipeline list --data-dir "$D2" | grep -q "functions=legacy-set@3" ||
  { "$EXE" pipeline list --data-dir "$D2"; fail "12: the v1 document did not load as one task"; }
"$EXE" pipeline apply -f "$WORK/task-b.json" --data-dir "$D2" > /dev/null 2>&1 ||
  fail "12: upserting into a v1 document failed"
python3 - "$D2/topology.json" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
if doc.get("schema") != 2:
    print("the rewritten document is not v2:", doc.get("schema"), file=sys.stderr)
    sys.exit(1)
names = [t["pipeline"] for t in doc["pipelines"]]
if names != ["task-a", "task-b"]:
    print("wrong tasks after migration:", names, file=sys.stderr)
    sys.exit(1)
a = [t for t in doc["pipelines"] if t["pipeline"] == "task-a"][0]
if a["functions"] != [{"name": "legacy-set", "revision": 3}]:
    print("the legacy task's recorded function sets were lost:", a["functions"], file=sys.stderr)
    sys.exit(1)
if "cluster_revision" in doc:
    print("a local apply must drop the cluster revision", file=sys.stderr)
    sys.exit(1)
PY
[ $? -eq 0 ] || fail "12: the v1 -> v2 migration lost something"
pass "12. a v1 document loads as one task, and the next write is v2 with the sibling intact"

# ---- 13. `pipeline run` refuses an ambiguous set, --name selects ---------
OUT=$("$EXE" pipeline run --data-dir "$D" 2>&1)
echo "$OUT" | grep -q "the applied set has 2 tasks (task-a, task-b); pass --name <task>" ||
  { echo "$OUT"; fail "13: an ambiguous run was not refused with the task list"; }
"$EXE" pipeline run --data-dir "$D" --name task-b > "$WORK/run-b.out" 2> "$WORK/run-b.err" &
RUNPID=$!
PIDS="$PIDS $RUNPID"
for _ in $(seq 1 40); do
  grep -q "opened pb" "$WORK/run-b.err" && break
  sleep 0.1
done
kill "$RUNPID" 2>/dev/null
grep -q "opened pb" "$WORK/run-b.err" ||
  { cat "$WORK/run-b.err"; fail "13: --name task-b did not run that task"; }
pass "13. an ambiguous set is refused by name, and --name runs the selected task"

echo "E2E-P37-MULTI-TASK: $PASS passed, 0 failed"
