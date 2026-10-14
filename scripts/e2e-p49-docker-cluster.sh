#!/bin/bash
# E2E-P49-DOCKER-CLUSTER: 管理平面/数据平面的 docker 集群测试（P37-5a 收口）
#
# 用户给的完成判据："构建 docker 环境下的集群测试"。这条门禁在 docker 里起一个
# 真集群——sc（控制面）+ spu-a/spu-b（数据面）+ runner（worker）——断言管理平面真的
# 协调了 worker：
#
#   1  镜像能从干净检出构建（与 p42 同一份 Dockerfile，自装工具链、自构建平台）
#   2  sc 起来后，两个 spu 注册到控制面（`cluster spu list` 看到 2 个数据节点）
#   3  runner 起的任务在**控制面**可见（`run list --remote sc` 里 running，带 pid）
#   4  `docker stop` runner（SIGTERM）→ 子进程优雅停止 → run list 变 stopped，不是 offline
#
# 与 p42 同一纪律：本地开发机没有 docker daemon（只有 client），所以这条门禁也有
# 两半——静态半在本机/快套件里跑，动态半只在 CI 的 docker 作业里强制（MOONFLUX_REQUIRE_DOCKER=1），
# 本地不静默跳过（缺 daemon 时静态半照跑、并明说哪一半没跑）。
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

TAG="${MOONFLUX_DOCKER_TAG:-moonflux:gate}"
WORK="$(mktemp -d /tmp/moonflux-p49.XXXXXX)"
DOCKERFILE="$ROOT/deploy/docker/Dockerfile"
COMPOSE="$ROOT/deploy/docker/compose.yaml"
PASS=0
CONTAINERS=""

fail() { echo "E2E-P49-DOCKER-CLUSTER FAIL: $*" >&2; exit 1; }
pass() { echo "E2E-P49-DOCKER-CLUSTER PASS: $*"; PASS=$((PASS + 1)); }

cleanup() {
  for c in $CONTAINERS; do docker rm -f "$c" > /dev/null 2>&1 || true; done
  docker network rm moonflux-p49 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

docker_daemon() { docker info > /dev/null 2>&1; }

# ---------------------------------------------------------------------
# 静态半：真或假都能跑
[ -f "$DOCKERFILE" ] || fail "deploy/docker/Dockerfile is missing"
[ -f "$COMPOSE" ] || fail "deploy/docker/compose.yaml is missing"
python3 - "$COMPOSE" <<'PY' || fail "the compose file lost the cluster services"
import pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
for needle in ["  sc:", "  spu-a:", "  spu-b:", "  runner:", "profiles: [\"cluster\"]"]:
    if needle not in text:
        print(f"compose is missing {needle!r}", file=sys.stderr)
        sys.exit(1)
PY
pass "static: compose declares sc/spu-a/spu-b/runner under the cluster profile"

# the runner subcommand must exist, or the worker half has no entry point
grep -q '"runner" => cmd_runner' "$ROOT/apps/cli/main.mbt" ||
  fail "the CLI has no runner subcommand, so nothing in the image supervises tasks"
pass "static: the CLI dispatches runner"

# the CI docker job must run this gate with the dynamic half mandatory
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
pass "dynamic: the image builds"

docker network create moonflux-p49 > /dev/null 2>&1 || true
mkdir -p "$WORK/sc" "$WORK/spu-a" "$WORK/spu-b" "$WORK/runner"
chmod 777 "$WORK/sc" "$WORK/spu-a" "$WORK/spu-b" "$WORK/runner"

# ---- sc（控制面） -------------------------------------------------------
docker run -d --name mf-p49-sc --network moonflux-p49 --network-alias sc \
  -v "$WORK/sc:/data" "$TAG" sc --listen 0.0.0.0:19900 --data-dir /data > /dev/null ||
  fail "the sc container did not start"
CONTAINERS="$CONTAINERS mf-p49-sc"

# ---- spu-a / spu-b（数据面） -------------------------------------------
docker run -d --name mf-p49-spu-a --network moonflux-p49 --network-alias spu-a \
  -v "$WORK/spu-a:/data" "$TAG" spu --id spu-a --listen 0.0.0.0:19901 --data-dir /data --sc sc:19900 > /dev/null ||
  fail "the spu-a container did not start"
CONTAINERS="$CONTAINERS mf-p49-spu-a"
docker run -d --name mf-p49-spu-b --network moonflux-p49 --network-alias spu-b \
  -v "$WORK/spu-b:/data" "$TAG" spu --id spu-b --listen 0.0.0.0:19902 --data-dir /data --sc sc:19900 > /dev/null ||
  fail "the spu-b container did not start"
CONTAINERS="$CONTAINERS mf-p49-spu-b"

# wait for the two data nodes to register with the control plane
for _ in $(seq 1 150); do
  N=$(docker exec mf-p49-sc /usr/local/bin/moonflux cluster spu list --remote 127.0.0.1:19900 2>/dev/null | grep -c spu- || true)
  [ "$N" = "2" ] && break
  sleep 0.2
done
N=$(docker exec mf-p49-sc /usr/local/bin/moonflux cluster spu list --remote 127.0.0.1:19900 2>/dev/null | grep -c spu- || true)
[ "$N" = "2" ] ||
  { docker logs mf-p49-sc 2>&1 | tail -5; docker logs mf-p49-spu-a 2>&1 | tail -5; fail "the two data nodes did not register (saw $N)"; }
pass "dynamic: 两个 spu 注册到控制面（cluster spu list 见 2 个数据节点）"

# ---- runner（worker）：apply 一个 relay 任务集，然后常驻监督 ------------
cat > "$WORK/relay.json" <<'JSON'
{"apiVersion":"moonflux.io/v1alpha1","kind":"Pipeline","metadata":{"name":"relay"},
 "spec":{"source":{"type":"topic","name":"relay-in","from":"beginning"},"topic":{"name":"relay-in"},
 "transforms":[],"sink":{"type":"stdout"}}}
JSON
# the image's ENTRYPOINT is the moonflux binary, so a shell command needs
# --entrypoint /bin/sh (the same shape p42 uses for its in-container case run)
docker run -d --name mf-p49-runner --network moonflux-p49 --network-alias runner \
  -v "$WORK/runner:/data" -v "$WORK/relay.json:/spec.json" \
  --entrypoint /bin/sh "$TAG" -lc \
  '/usr/local/bin/moonflux pipeline apply -f /spec.json --data-dir /data && exec /usr/local/bin/moonflux runner --data-dir /data --control sc:19900 --cli /usr/local/bin/moonflux' \
  > /dev/null || fail "the runner container did not start"
CONTAINERS="$CONTAINERS mf-p49-runner"

# wait for the task to register with the control plane
for _ in $(seq 1 150); do
  docker exec mf-p49-sc /usr/local/bin/moonflux run list --remote 127.0.0.1:19900 2>/dev/null | grep -q "task=relay	state=running" && break
  sleep 0.2
done
LINE=$(docker exec mf-p49-sc /usr/local/bin/moonflux run list --remote 127.0.0.1:19900 2>/dev/null | grep "task=relay" | head -1)
echo "$LINE" | grep -q "state=running" ||
  { docker logs mf-p49-runner 2>&1 | tail -8; fail "the runner's task did not register with the control plane"; }
echo "$LINE" | grep -qE "pid=[0-9]+" || { echo "$LINE"; fail "the registered task has no pid"; }
pass "dynamic: runner 起的任务在控制面可见（${LINE}）"

# ---- graceful stop across containers -----------------------------------
docker stop mf-p49-runner > /dev/null 2>&1
for _ in $(seq 1 150); do
  docker exec mf-p49-sc /usr/local/bin/moonflux run list --remote 127.0.0.1:19900 2>/dev/null | grep -q "task=relay	state=stopped" && break
  sleep 0.2
done
LINE2=$(docker exec mf-p49-sc /usr/local/bin/moonflux run list --remote 127.0.0.1:19900 2>/dev/null | grep "task=relay" | head -1)
echo "$LINE2" | grep -q "state=stopped" ||
  { echo "$LINE2"; fail "docker stop 后任务没有优雅停止（应是 stopped，不是 offline）"; }
pass "dynamic: docker stop runner → 任务优雅停止（${LINE2}）"

echo "E2E-P49-DOCKER-CLUSTER: $PASS passed, 0 failed (dynamic)"
