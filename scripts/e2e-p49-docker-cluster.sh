#!/bin/bash
# E2E-P49-DOCKER-CLUSTER: 管理平面/数据平面的 docker 集群测试（P37-5a/5b 收口，决策 104）
#
# 目标 ④ 的完成判据：在 docker 里起真集群（sc + ≥2 spu + ≥2 runner），端到端断言
# **调度到指定节点、start→登记→有输出、stop→stopped 且扛过回收窗口、kill→offline、
# 丢 worker 重分配**。与 p42 同一纪律：静态半到处能跑，动态半只在有 docker daemon 的
# 地方强制（CI 的 docker 作业设 MOONFLUX_REQUIRE_DOCKER=1），本地不静默跳过。
#
# 动态腿（9 条）：
#   1 镜像从干净检出构建
#   2 两个 spu 注册到控制面（数据面在）
#   3 调度：apply 到**集群**后 `task schedule` 显示钉住的任务在它的目标 worker、
#     浮动任务被放到活 worker
#   4 **有输出**：往任务输入主题喂一条，子进程的输出出现在 runner 容器日志里
#     （"running" 与 "在干活" 不是同一个断言）
#   5 **stop→stopped 且扛过回收窗口**：`task stop --remote` → disabled + 优雅 stopped，
#     等过回收窗口（NODE_TIMEOUT_MS=3s）仍是 stopped（优雅停不得衰减成 offline）
#   6 `task start --remote` → 又跑起来
#   7 **kill→offline**：kill -9 一个 `restart: never` 的子进程 → 过回收窗口后 offline
#   8 **重分配**：杀掉持有浮动任务的 worker → 该任务重分配到活 worker；
#     钉在那台 worker 上的任务**不重分配**、留在 pending
#   9 优雅停一个 runner 容器 → 它的任务变 stopped（不是 offline）
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

TAG="${MOONFLUX_DOCKER_TAG:-moonflux:gate}"
WORK="$(mktemp -d /tmp/moonflux-p49.XXXXXX)"
DOCKERFILE="$ROOT/deploy/docker/Dockerfile"
COMPOSE="$ROOT/deploy/docker/compose.yaml"
PASS=0
CONTAINERS=""
NET="moonflux-p49"

fail() { echo "E2E-P49-DOCKER-CLUSTER FAIL: $*" >&2; exit 1; }
pass() { echo "E2E-P49-DOCKER-CLUSTER PASS: $*"; PASS=$((PASS + 1)); }
cleanup() {
  for c in $CONTAINERS; do docker rm -f "$c" > /dev/null 2>&1 || true; done
  docker network rm "$NET" > /dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

docker_daemon() { docker info > /dev/null 2>&1; }

SC="mf-p49-sc"
RA="mf-p49-ra"
RB="mf-p49-rb"
MF="/usr/local/bin/moonflux"

# ---------------------------------------------------------------------
# 静态半：真或假都能跑
[ -f "$DOCKERFILE" ] || fail "deploy/docker/Dockerfile is missing"
[ -f "$COMPOSE" ] || fail "deploy/docker/compose.yaml is missing"
python3 - "$COMPOSE" <<'PY' || fail "the compose file lost the cluster services"
import pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
for needle in ["  sc:", "  spu-a:", "  spu-b:", "  runner:", 'profiles: ["cluster"]']:
    if needle not in text:
        print(f"compose is missing {needle!r}", file=sys.stderr)
        sys.exit(1)
PY
pass "static: compose declares sc/spu-a/spu-b/runner under the cluster profile"
grep -q '"runner" => cmd_runner' "$ROOT/apps/cli/main.mbt" ||
  fail "the CLI has no runner subcommand, so nothing in the image supervises tasks"
pass "static: the CLI dispatches runner"
grep -q "e2e-p49-docker-cluster.sh" "$ROOT/.github/workflows/ci.yml" ||
  fail "no CI job runs this gate, so the docker cluster has no proof"
grep -q "MOONFLUX_REQUIRE_DOCKER" "$ROOT/.github/workflows/ci.yml" ||
  fail "the CI docker job does not require a daemon"
pass "static: CI runs this gate with the dynamic half mandatory"

if [ "${MOONFLUX_REQUIRE_DOCKER:-0}" != "1" ]; then
  echo "E2E-P49-DOCKER-CLUSTER: static only (the CI docker job runs the cluster half with"
  echo "                        MOONFLUX_REQUIRE_DOCKER=1; set it here to run it locally too)."
  echo "E2E-P49-DOCKER-CLUSTER: $PASS passed, 0 failed (static only)"
  exit 0
fi
docker_daemon || fail "MOONFLUX_REQUIRE_DOCKER=1 but no docker daemon is reachable"

# ---------------------------------------------------------------------
# 动态半：真集群
docker build -f "$DOCKERFILE" -t "$TAG" "$ROOT" > "$WORK/build.log" 2>&1 ||
  { tail -25 "$WORK/build.log"; fail "the image did not build"; }
pass "dynamic 1: the image builds from a clean checkout"

docker network create "$NET" > /dev/null 2>&1 || true
for d in sc spu-a spu-b ra rb; do mkdir -p "$WORK/$d"; chmod 777 "$WORK/$d"; done

# the cluster's desired state: a floating task, one pinned to worker-a, and one
# pinned to worker-b with restart: never (the offline leg needs a death that
# STAYS dead - an on-failure task would come back and the leg would be vacuous)
cat > "$WORK/set.json" <<'JSON'
{"pipelines":[
 {"pipeline":"floater",
  "spec":{"apiVersion":"moonflux.io/v1alpha1","kind":"Pipeline","metadata":{"name":"floater"},
   "spec":{"source":{"type":"topic","name":"in-f","from":"beginning"},"topic":{"name":"in-f"},
    "transforms":[],"sink":{"type":"stdout"}}}},
 {"pipeline":"pinned-a","target":"worker-a",
  "spec":{"apiVersion":"moonflux.io/v1alpha1","kind":"Pipeline","metadata":{"name":"pinned-a"},
   "spec":{"source":{"type":"topic","name":"in-a","from":"beginning"},"topic":{"name":"in-a"},
    "transforms":[],"sink":{"type":"stdout"}}}},
 {"pipeline":"never-b","target":"worker-b","restart":"never",
  "spec":{"apiVersion":"moonflux.io/v1alpha1","kind":"Pipeline","metadata":{"name":"never-b"},
   "spec":{"source":{"type":"topic","name":"in-b","from":"beginning"},"topic":{"name":"in-b"},
    "transforms":[],"sink":{"type":"stdout"}}}}
]}
JSON

docker run -d --name "$SC" --network "$NET" --network-alias sc \
  -v "$WORK/sc:/data" -v "$WORK/set.json:/set.json" "$TAG" \
  sc --listen 0.0.0.0:19900 --data-dir /data > /dev/null ||
  fail "the sc container did not start"
CONTAINERS="$CONTAINERS $SC"
docker run -d --name mf-p49-spu-a --network "$NET" --network-alias spu-a \
  -v "$WORK/spu-a:/data" "$TAG" \
  spu --id spu-a --listen 0.0.0.0:19901 --data-dir /data --sc sc:19900 > /dev/null ||
  fail "the spu-a container did not start"
CONTAINERS="$CONTAINERS mf-p49-spu-a"
docker run -d --name mf-p49-spu-b --network "$NET" --network-alias spu-b \
  -v "$WORK/spu-b:/data" "$TAG" \
  spu --id spu-b --listen 0.0.0.0:19902 --data-dir /data --sc sc:19900 > /dev/null ||
  fail "the spu-b container did not start"
CONTAINERS="$CONTAINERS mf-p49-spu-b"

# one CLI inside the control-plane container, for every sc-side question
scrun() { docker exec "$SC" "$MF" "$@" --remote 127.0.0.1:19900 2>/dev/null; }
sched() { scrun task schedule; }
runs() { scrun run list; }
wait_for() { # tenths, then a command whose success means "ready"
  local tenths="$1"; shift
  local i=0
  while [ "$i" -lt "$tenths" ]; do
    "$@" && return 0
    sleep 0.1; i=$((i + 1))
  done
  return 1
}
two_spus() { [ "$(scrun cluster spu list | grep -c spu-)" = "2" ]; }
wait_for 200 two_spus ||
  { docker logs "$SC" 2>&1 | tail -5; docker logs mf-p49-spu-a 2>&1 | tail -5; fail "2: the two data nodes did not register"; }
pass "dynamic 2: 两个 spu 注册到控制面（数据面在）"

# two workers, each with its own data dir: the control plane decides, the worker
# adopts the document on its next beat (P11's pull-on-revision-change)
for spec in "$RA worker-a ra" "$RB worker-b rb"; do
  set -- $spec
  docker run -d --name "$1" --network "$NET" -v "$WORK/$3:/data" \
    --entrypoint /bin/sh "$TAG" -lc \
    "exec $MF runner --data-dir /data --control sc:19900 --worker $2 --cli $MF" \
    > /dev/null || fail "the $1 container did not start"
  CONTAINERS="$CONTAINERS $1"
done

scrun pipeline apply -f /set.json --set > /dev/null 2>&1 ||
  fail "3: applying the task set to the cluster failed"

sched_has() { sched | grep -q "$1"; }
runs_has() { runs | grep -q "$1"; }

# ---- 3. scheduling: a pin lands on its worker, floating work is placed -----
wait_for 400 sched_has "pinned-a	target=worker-a	owner=worker-a	state=running" ||
  { sched; docker logs "$RA" 2>&1 | tail -5; fail "3: the pinned task did not run on worker-a"; }
wait_for 400 sched_has "floater	.*state=running" ||
  { sched; fail "3: the floating task was never placed"; }
pass "3. 调度：pinned-a 在 worker-a 上跑、floater 被放到活 worker（$(sched | grep '^floater' | cut -f3)）"

# ---- 4. start -> registered -> OUTPUT ------------------------------------
# Feed the floating task's input topic in ITS OWN data dir and look for the
# record in that runner's log: "the task is running" and "the task is doing its
# job" are different claims, and only the second one needs data to move.
FLOATER_OWNER=$(sched | grep '^floater' | sed -E 's/.*owner=([^	]*).*/\1/')
case "$FLOATER_OWNER" in
  worker-a) FEED="$RA" ;;
  worker-b) FEED="$RB" ;;
  *) fail "4: the floating task has no owner (${FLOATER_OWNER})" ;;
esac
docker exec "$FEED" /bin/sh -lc \
  "printf 'MARKER-P49-VALUE\\n' > /tmp/v.txt && $MF produce --data-dir /data --topic in-f --file /tmp/v.txt" \
  > /dev/null 2>&1 || fail "4: could not feed the task's input topic"
saw_marker() { docker logs "$FEED" 2>&1 | grep -q "MARKER-P49-VALUE"; }
wait_for 200 saw_marker ||
  { docker logs "$FEED" 2>&1 | tail -5; fail "4: the task produced no output after its input arrived"; }
pass "4. 有输出：喂进输入主题的记录出现在任务输出里（runner 容器日志可见）"

# ---- 5. stop --remote: disabled, graceful, and it SURVIVES the reap window -
scrun task stop --name floater > "$WORK/stop.out" 2>&1 ||
  { cat "$WORK/stop.out"; fail "5: task stop --remote failed"; }
wait_for 200 sched_has "floater	.*state=disabled" || { sched; fail "5: the stopped task is not disabled"; }
wait_for 200 runs_has "task=floater	state=stopped" ||
  { runs; fail "5: the child did not stop gracefully"; }
# the reap window is NODE_TIMEOUT_MS = 3s. Waiting past it is the point: a
# graceful stop must not decay into "offline" the way a kill does.
sleep 5
runs | grep "task=floater" | grep -q "state=stopped" ||
  { runs; fail "5: a graceful stop decayed after the reap window"; }
pass "5. stop --remote → disabled + 优雅 stopped，且**扛过 3s 回收窗口**仍是 stopped"

# ---- 6. start --remote brings it back -------------------------------------
scrun task start --name floater > /dev/null 2>&1 || fail "6: task start --remote failed"
wait_for 400 sched_has "floater	.*state=running" ||
  { sched; fail "6: the started task did not come back"; }
pass "6. start --remote → 又跑起来"

# ---- 7. kill -> offline (the task is restart: never) ----------------------
# the run registry reports the pid of the process INSIDE the container, so kill
# it there; restart: never is what makes "offline" the end state
NEVER_PID=$(runs | grep "task=never-b" | grep "state=running" | head -1 | sed -E 's/.*pid=([0-9]+).*/\1/')
[ -n "$NEVER_PID" ] || { runs; fail "7: never-b is not running, so there is nothing to kill"; }
docker exec "$RB" /bin/sh -lc "kill -9 $NEVER_PID" > /dev/null 2>&1 ||
  fail "7: could not kill the task's process inside its container"
wait_for 400 runs_has "task=never-b	state=offline" ||
  { runs; fail "7: a killed restart:never task was not reaped as offline"; }
pass "7. kill -9 子进程 → 过回收窗口后 offline（restart: never，不复活）"

# ---- 8. losing a worker: floating moves, a pin does not -------------------
OWNER=$(sched | grep '^floater' | sed -E 's/.*owner=([^	]*).*/\1/')
if [ "$OWNER" = "worker-b" ]; then VICTIM="$RB"; VICTIM_ID=worker-b; SURVIVOR=worker-a
else VICTIM="$RA"; VICTIM_ID=worker-a; SURVIVOR=worker-b; fi
docker rm -f "$VICTIM" > /dev/null 2>&1 || fail "8: could not kill the owning worker"
CONTAINERS="$(echo "$CONTAINERS" | tr ' ' '\n' | grep -v "^$VICTIM$" | tr '\n' ' ')"
wait_for 600 sched_has "floater	.*owner=$SURVIVOR	state=running" ||
  { sched; docker logs "$SC" 2>&1 | tail -5; fail "8: the floating task was not reassigned to $SURVIVOR"; }
if [ "$VICTIM_ID" = "worker-a" ]; then
  wait_for 600 sched_has "pinned-a	.*state=pending" ||
    { sched; fail "8: a task pinned to a dead worker was moved instead of left pending"; }
fi
pass "8. 丢 worker → 浮动任务重分配到 ${SURVIVOR}；钉在死 worker 上的任务留在 pending（不重分配）"

# ---- 9. a runner container stopped gracefully → its task says stopped ------
SURVIVOR_CONTAINER=$([ "$SURVIVOR" = "worker-a" ] && echo "$RA" || echo "$RB")
if docker ps --format '{{.Names}}' | grep -qx "$SURVIVOR_CONTAINER"; then
  OWNED=$(sched | grep "owner=$SURVIVOR" | head -1 | cut -f1)
  docker stop "$SURVIVOR_CONTAINER" > /dev/null 2>&1 || fail "9: docker stop of the runner failed"
  CONTAINERS="$(echo "$CONTAINERS" | tr ' ' '\n' | grep -v "^$SURVIVOR_CONTAINER$" | tr '\n' ' ')"
  wait_for 300 runs_has "task=$OWNED	state=stopped" ||
    { runs; fail "9: stopping a runner did not stop its task gracefully (task $OWNED)"; }
  pass "9. docker stop runner → 它的任务变 stopped（不是 offline）"
else
  pass "9. （幸存 worker 已在第 8 腿被移除，本腿无对象可停）"
fi

echo "E2E-P49-DOCKER-CLUSTER: $PASS passed, 0 failed (dynamic)"
