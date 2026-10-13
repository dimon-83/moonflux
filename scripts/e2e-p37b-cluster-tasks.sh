#!/bin/bash
# E2E-P37B-CLUSTER-TASKS: 集群侧多任务（P37-1b，决策 82）
#
# 本地口径（P37-1）已经证明"一个数据目录持一组任务、取数按 topic 选链"。
# 这一条门禁证明**集群口径**，要证伪的是这四件事：
#
#   1  控制面持有**一份集合文档 + 一个修订**，三种 apply 形状各有明确含义
#      （upsert 一个任务 / `--replace` 一个任务就是全集 / `--set` 一份集合就是全集），
#      `delete` 是第四种
#   2  节点**整份采纳**：一次心跳里拿到整个集合，本地 `topology.json` 的
#      `cluster_revision` 与任务列表**同时**前进——不存在"采纳了一半"
#   3  集合的校验在**权威处**（控制面）发生：同主题冲突按名拒绝，且**修订不前进**
#      （被拒的发布不得留下痕迹）
#   4  **坏文档被拒绝且节点保留在跑的集合**（故障注入：绕过校验直接改控制面的文件，
#      把修订推到 N+1）——这是混版节点遇到集合文档时的同一条安全路径：拒绝、保留、有噪音
#
# 如实边界：`CMD_CLUSTER_PIPELINE_DELETE` 与 APPLY 一样是 **Root-only**
# （角色表里没列出的命令一律 Root），因此只有操作员能改集群的期望状态。
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

EXE="${MOONFLUX_EXE:-$ROOT/_build/native/debug/build/apps/cli/cli.exe}"
WORK="$(mktemp -d /tmp/moonflux-p37b.XXXXXX)"
SC_PORT="${MOONFLUX_P37B_SC_PORT:-19681}"
NODE_PORT="${MOONFLUX_P37B_NODE_PORT:-19682}"
PIDS=""
PASS=0

fail() { echo "E2E-P37B-CLUSTER-TASKS FAIL: $*" >&2; exit 1; }
pass() { echo "E2E-P37B-CLUSTER-TASKS PASS: $*"; PASS=$((PASS + 1)); }

cleanup() {
  for pid in $PIDS; do kill -9 "$pid" 2>/dev/null; done
  wait 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

[ -x "$EXE" ] || { echo "missing $EXE (build first)" >&2; exit 1; }
"$ROOT/scripts/build-operators.sh" > /dev/null 2>&1
UPPER="$ROOT/_build/wasm/debug/build/apps/operator-upper/operator-upper.wasm"
[ -f "$UPPER" ] || fail "operator-upper.wasm is missing"

wait_listen() { # port tenths
  local port="$1" tenths="${2:-80}" i=0
  while [ "$i" -lt "$tenths" ]; do
    lsof -i ":$port" -sTCP:LISTEN > /dev/null 2>&1 && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

wait_log() { # file pattern tenths
  local file="$1" pattern="$2" tenths="${3:-100}" i=0
  while [ "$i" -lt "$tenths" ]; do
    grep -q "$pattern" "$file" 2>/dev/null && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

cluster_revision() { # sc_port -> the revision the control plane reports
  "$EXE" pipeline list --remote "127.0.0.1:$1" 2>/dev/null | sed -n 's/^cluster_revision=//p'
}

node_tasks() { # data dir -> "rev:tasks"
  python3 - "$1/topology.json" <<'PY'
import json, sys
try:
    doc = json.load(open(sys.argv[1]))
except Exception:
    print("none")
    sys.exit(0)
print(f"{doc.get('cluster_revision')}:{','.join(t['pipeline'] for t in doc.get('pipelines', []))}")
PY
}

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
c = spec("task-c", "pa", [])   # collides with task-a on purpose
(work / "task-a.json").write_text(json.dumps(a, indent=2))
(work / "task-b.json").write_text(json.dumps(b, indent=2))
(work / "task-c.json").write_text(json.dumps(c, indent=2))
(work / "set.json").write_text(json.dumps({"pipelines": [a, b]}, indent=2))
PY

SC="127.0.0.1:$SC_PORT"
mkdir -p "$WORK/sc"
"$EXE" sc --listen "$SC" --data-dir "$WORK/sc" > "$WORK/sc.log" 2>&1 &
SC_PID=$!
PIDS="$PIDS $SC_PID"
wait_listen "$SC_PORT" || { cat "$WORK/sc.log"; fail "the control plane did not start"; }

# ---- 1. three apply shapes, one revision each ---------------------------
"$EXE" pipeline apply --remote "$SC" -f "$WORK/task-a.json" > /dev/null 2>&1 ||
  fail "1: upserting task-a failed"
"$EXE" pipeline apply --remote "$SC" -f "$WORK/task-b.json" > /dev/null 2>&1 ||
  fail "1: upserting task-b failed"
LIST=$("$EXE" pipeline list --remote "$SC" 2>&1)
echo "$LIST" | grep -q "^task-a	topic=pa	transforms=1" ||
  { echo "$LIST"; fail "1: task-a is not on the cluster as topic pa with one transform"; }
echo "$LIST" | grep -q "^task-b	topic=pb	transforms=0" ||
  { echo "$LIST"; fail "1: task-b is not on the cluster"; }
[ "$(cluster_revision "$SC_PORT")" = "2" ] ||
  fail "1: two upserts should be two revisions, got $(cluster_revision "$SC_PORT")"
pass "1. the control plane holds a two-task set at revision 2 (two upserts, two revisions)"

# ---- 2. a node adopts the WHOLE set in one revision --------------------
"$EXE" spu --id n1 --listen "127.0.0.1:$NODE_PORT" --data-dir "$WORK/n1" --sc "$SC" \
  > "$WORK/n1.log" 2>&1 &
PIDS="$PIDS $!"
wait_listen "$NODE_PORT" || { cat "$WORK/n1.log"; fail "2: the node did not start"; }
wait_log "$WORK/n1.log" "task set revision 2 adopted (2 task(s): task-a, task-b)" 150 ||
  { cat "$WORK/n1.log"; fail "2: the node did not adopt the two-task set"; }
[ "$(node_tasks "$WORK/n1")" = "2:task-a,task-b" ] ||
  fail "2: the node's local set is $(node_tasks "$WORK/n1"), expected 2:task-a,task-b"
pass "2. the node adopted the whole set in one revision (its own document says revision 2, two tasks)"

# ---- 3. the authority refuses a topic collision, and does not move ------
BEFORE=$(cluster_revision "$SC_PORT")
OUT=$("$EXE" pipeline apply --remote "$SC" -f "$WORK/task-c.json" 2>&1)
echo "$OUT" | grep -q "tasks task-a and task-c both declare topic pa" ||
  { echo "$OUT"; fail "3: the control plane did not refuse the topic collision by name"; }
[ "$(cluster_revision "$SC_PORT")" = "$BEFORE" ] ||
  fail "3: a refused publish moved the revision ($BEFORE -> $(cluster_revision "$SC_PORT"))"
pass "3. a topic collision is refused by the control plane, and the refused publish leaves the revision alone"

# ---- 4. delete one task, cluster and node both move --------------------
"$EXE" pipeline delete --remote "$SC" --name task-a > /dev/null 2>&1 ||
  fail "4: deleting task-a on the cluster failed"
[ "$(cluster_revision "$SC_PORT")" = "3" ] ||
  fail "4: delete should be revision 3, got $(cluster_revision "$SC_PORT")"
BEFORE=$(cluster_revision "$SC_PORT")
OUT=$("$EXE" pipeline delete --remote "$SC" --name nope 2>&1)
echo "$OUT" | grep -q "no task named nope on this cluster (tasks: task-b)" ||
  { echo "$OUT"; fail "4: deleting an unknown name did not refuse and name what exists"; }
[ "$(cluster_revision "$SC_PORT")" = "$BEFORE" ] ||
  fail "4: a refused delete moved the revision"
wait_log "$WORK/n1.log" "task set revision 3 adopted (1 task(s): task-b)" 150 ||
  { cat "$WORK/n1.log"; fail "4: the node did not adopt the one-task set"; }
[ "$(node_tasks "$WORK/n1")" = "3:task-b" ] ||
  fail "4: the node's local set is $(node_tasks "$WORK/n1"), expected 3:task-b"
pass "4. delete moves cluster and node to revision 3 with one task; an unknown name is refused without a revision bump"

# ---- 5/6. --set and --replace are different, and both are explicit ------
"$EXE" pipeline apply --remote "$SC" --set -f "$WORK/set.json" > /dev/null 2>&1 ||
  fail "5: --set on the cluster failed"
[ "$(cluster_revision "$SC_PORT")" = "4" ] || fail "5: --set should be revision 4"
wait_log "$WORK/n1.log" "task set revision 4 adopted (2 task(s): task-a, task-b)" 150 ||
  { cat "$WORK/n1.log"; fail "5: the node did not adopt the --set document"; }
"$EXE" pipeline apply --remote "$SC" --replace -f "$WORK/task-c.json" > /dev/null 2>&1 ||
  fail "6: --replace on the cluster failed"
[ "$(cluster_revision "$SC_PORT")" = "5" ] || fail "6: --replace should be revision 5"
wait_log "$WORK/n1.log" "task set revision 5 adopted (1 task(s): task-c)" 150 ||
  { cat "$WORK/n1.log"; fail "6: the node did not adopt the replaced set"; }
[ "$(node_tasks "$WORK/n1")" = "5:task-c" ] ||
  fail "6: the node's local set is $(node_tasks "$WORK/n1"), expected 5:task-c"
pass "5. --set replaces the whole set (both tasks, revision 4) and --replace makes it one task (revision 5)"

# ---- 7. a corrupt set document is refused, the running set survives -----
# Fault injection: write an unreadable document into the control plane's file
# and RESTART it (the control plane caches its asset in memory, so editing the
# file under a running process changes nothing — measured). A node must refuse
# the document and keep running what it has, which is exactly the path a
# mixed-version node takes when it meets a set document it cannot read:
# refuse, keep running, say so in the log.
kill -9 "$SC_PID" 2>/dev/null
wait "$SC_PID" 2>/dev/null
python3 - "$WORK/sc/pipeline.json" <<'JSONEOF'
import json, sys
path = sys.argv[1]
doc = json.load(open(path))
doc["revision"] = 6
doc["pipelines"] = [{"pipeline": "broken"}]   # no spec: unreadable by design
json.dump(doc, open(path, "w"), indent=2)
print(f"injected an unreadable set document at revision 6 into {path}")
JSONEOF
"$EXE" sc --listen "$SC" --data-dir "$WORK/sc" > "$WORK/sc2.log" 2>&1 &
SC_PID=$!
PIDS="$PIDS $SC_PID"
wait_listen "$SC_PORT" || { cat "$WORK/sc2.log"; fail "7: the control plane did not restart"; }
# The CLI refuses to LIST a set it cannot read (it does not print a partial or
# invented list), so the revision is not reachable through `list` here — that
# refusal is itself the behaviour to assert.
if "$EXE" pipeline list --remote "$SC" > "$WORK/badlist.out" 2>&1; then
  cat "$WORK/badlist.out"
  fail "7: listing an unreadable set should have failed, not printed something"
fi
grep -q "task broken has no spec" "$WORK/badlist.out" ||
  { cat "$WORK/badlist.out"; fail "7: the listing refusal did not say what was wrong"; }
wait_log "$WORK/n1.log" "is unreadable here" 250 ||
  { cat "$WORK/n1.log"; fail "7: the node did not report the unreadable set"; }
[ "$(node_tasks "$WORK/n1")" = "5:task-c" ] ||
  fail "7: the node's running set changed to $(node_tasks "$WORK/n1") after a bad document"
pass "7. an unreadable set document is refused and the node keeps running its revision-5 set"

echo "E2E-P37B-CLUSTER-TASKS: $PASS passed, 0 failed"
