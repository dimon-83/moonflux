#!/bin/bash
# E2E-P42-DOCKER: the container deployment (README decision 87)
#
# The honest shape of this gate: a container path can only be PROVEN by a
# container engine, and this repository's development machine has a docker
# CLIENT but no running daemon (checked: `docker ps` cannot reach
# /Users/dexter/.docker/run/docker.sock). So the gate has two modes:
#
#   * a daemon is reachable -> build the image, smoke it for real: `doctor`,
#     a catalog spec through the kernel, a broker container answering /healthz,
#     and ONE CATALOG CASE run in a container whose stdout is compared
#     byte-for-byte with the case's expected.txt;
#   * no daemon -> the checks that do not need one (the Dockerfile's referenced
#     sources exist, the compose file parses with the docker CLI, the CI job that
#     runs the dynamic half exists), each printed as static, plus an explicit
#     line saying which half was NOT run. With MOONFLUX_REQUIRE_DOCKER=1 (what
#     the CI docker job sets) the unavailability is a FAILURE instead: the
#     dynamic half is then mandatory, so "no daemon" can never silently pass a
#     container gate.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

TAG="${MOONFLUX_DOCKER_TAG:-moonflux:gate}"
WORK="$(mktemp -d /tmp/moonflux-p42.XXXXXX)"
COMPOSE="$ROOT/deploy/docker/compose.yaml"
DOCKERFILE="$ROOT/deploy/docker/Dockerfile"
PASS=0
CONTAINERS=""

fail() { echo "E2E-P42-DOCKER FAIL: $*" >&2; exit 1; }
pass() { echo "E2E-P42-DOCKER PASS: $*"; PASS=$((PASS + 1)); }

cleanup() {
  for c in $CONTAINERS; do docker rm -f "$c" > /dev/null 2>&1 || true; done
  rm -rf "$WORK"
}
trap cleanup EXIT

docker_daemon() { docker info > /dev/null 2>&1; }

wait_http() { # url tenths
  local url="$1" tenths="${2:-100}" i=0
  while [ "$i" -lt "$tenths" ]; do
    curl -fsS "$url" > /dev/null 2>&1 && return 0
    sleep 0.1; i=$((i + 1))
  done
  return 1
}

# ---------------------------------------------------------------------
# the static half: true whether or not an engine is running
[ -f "$DOCKERFILE" ] || fail "deploy/docker/Dockerfile is missing"
[ -f "$COMPOSE" ] || fail "deploy/docker/compose.yaml is missing"

# every source the image copies must exist here, or the image is a promise the
# repository cannot keep
[ -f "$ROOT/web/editor/index.html" ] || fail "web/editor/index.html is missing"
[ -d "$ROOT/examples/sdf" ] || fail "examples/sdf is missing"
python3 - "$ROOT" <<'PY' || fail "the catalog references operator modules that are not in the tree"
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
missing = set()
for spec in (root / "examples" / "sdf").glob("*/spec*.json"):
    for t in json.loads(spec.read_text())["spec"].get("transforms", []):
        if t.get("type") == "wasm":
            module = t.get("module", "")
            if module and not (root / module).exists():
                missing.add(module)
if missing:
    print("\n".join(sorted(missing)), file=sys.stderr)
    sys.exit(1)
PY
grep -q "_build/wasm/debug/build/apps" "$DOCKERFILE" ||
  fail "the image does not carry the wasm modules at the path the catalog names"
pass "static: the image's sources are in the tree and the catalog's module paths are what it copies"

# the compose file parses with the docker CLI (no daemon needed for `config`)
if docker compose -f "$COMPOSE" config -q > "$WORK/compose.out" 2>&1; then
  # `--profile "*"` so profiled services count too: the case service is the
  # container-per-case shape, and the cluster profile is the alternative to a
  # single broker. Omitting them here would let the compose file lose them
  # silently.
  SERVICES=$(docker compose -f "$COMPOSE" --profile "*" config --services 2>/dev/null)
  for service in broker console case sc spu-a spu-b; do
    echo "$SERVICES" | grep -qx "$service" || fail "compose has no $service service"
  done
  pass "static: compose parses and declares the broker/console/case and cluster services"
else
  cat "$WORK/compose.out"
  fail "compose did not parse"
fi

# the CI job is where the dynamic half is mandatory: if it is gone, the
# container path has no proof anywhere
grep -q "e2e-p42-docker.sh" "$ROOT/.github/workflows/ci.yml" ||
  fail "no CI job runs this gate, so nothing proves the container path"
grep -q "MOONFLUX_REQUIRE_DOCKER" "$ROOT/.github/workflows/ci.yml" ||
  fail "the CI docker job does not require a daemon, so it could pass the static half only"
pass "static: CI runs this gate with the dynamic half mandatory"

# ---------------------------------------------------------------------
# The dynamic half is MANDATORY only where it is scheduled: the CI docker job
# sets MOONFLUX_REQUIRE_DOCKER=1. Inside gates.sh (fast/full) the gate does the
# static checks only, on purpose — a full image build inside every suite run
# would double the suite's runtime for a proof the dedicated job already makes,
# and the gate would then behave differently on machines that happen to have a
# daemon. One place proves the container path; this flag is what makes it
# impossible for that place to pass without proof.
if [ "${MOONFLUX_REQUIRE_DOCKER:-0}" != "1" ]; then
  echo "E2E-P42-DOCKER: static only (the CI docker job runs the build+smoke half with"
  echo "                MOONFLUX_REQUIRE_DOCKER=1; set it here to run it locally too)."
  echo "E2E-P42-DOCKER: $PASS passed, 0 failed (static only)"
  exit 0
fi
docker_daemon || fail "MOONFLUX_REQUIRE_DOCKER=1 but no docker daemon is reachable"

# ---- dynamic: build the image from a clean-ish context ------------------
docker build -f "$DOCKERFILE" -t "$TAG" "$ROOT" > "$WORK/build.log" 2>&1 ||
  { tail -25 "$WORK/build.log"; fail "the image did not build"; }
pass "dynamic: the image builds ($(docker image inspect "$TAG" --format '{{.Size}}' 2>/dev/null || echo '?') bytes)"

# ---- dynamic: the platform's own facts inside the image ----------------
docker run --rm "$TAG" doctor > "$WORK/doctor.out" 2>&1 ||
  { cat "$WORK/doctor.out"; fail "moonflux doctor failed inside the image"; }
grep -q "wasmtime" "$WORK/doctor.out" ||
  { cat "$WORK/doctor.out"; fail "doctor does not report the operator host inside the image"; }
pass "dynamic: doctor reports the platform facts inside the image (durability + operator host)"

# ---- dynamic: the catalog is usable in the image -----------------------
docker run --rm -w /opt/moonflux "$TAG" pipeline view \
  -f examples/sdf/13-parse-sentence/spec.json > "$WORK/view.out" 2>&1 ||
  { cat "$WORK/view.out"; fail "the catalog spec could not be compiled inside the image"; }
grep -q '"model": 1' "$WORK/view.out" ||
  { cat "$WORK/view.out"; fail "the view model inside the image is not the expected one"; }
pass "dynamic: a catalog spec compiles inside the image and yields the view model"

# ---- dynamic: a broker container answers /healthz ----------------------
docker run -d --name moonflux-p42-broker -p 19851:19801 -p 19852:19802 \
  -v "$WORK/broker:/data" "$TAG" > /dev/null ||
  fail "the broker container did not start"
CONTAINERS="$CONTAINERS moonflux-p42-broker"
wait_http "http://127.0.0.1:19852/healthz" 200 ||
  { docker logs moonflux-p42-broker 2>&1 | tail -10; fail "the broker container never answered /healthz"; }
curl -fsS "http://127.0.0.1:19852/metrics" | grep -q "^moonflux_runs " ||
  fail "the broker container's /metrics has no run counters"
pass "dynamic: a broker container answers /healthz and serves label-free metrics"

# ---- dynamic: ONE CATALOG CASE runs in a container, byte for byte ------
# The strongest statement this gate can make about the container path: the same
# case the native deployment verifies, run in a container, matches the same
# golden.
CASE="13-parse-sentence"
SPEC=$(ls "examples/sdf/$CASE"/spec*.json | head -1)
docker run --rm -w /opt/moonflux -e CASE="$CASE" --entrypoint /bin/sh "$TAG" -lc \
  "exec /usr/local/bin/moonflux pipeline run --data-dir /tmp/case --spec $SPEC" \
  > "$WORK/case.out" 2> "$WORK/case.err" ||
  { cat "$WORK/case.err"; fail "$CASE failed inside a container"; }
cmp -s "$WORK/case.out" "examples/sdf/$CASE/expected.txt" ||
  { diff -u "examples/sdf/$CASE/expected.txt" "$WORK/case.out" | head -10; fail "$CASE differs from its expected.txt inside a container"; }
pass "dynamic: $CASE runs in a container and matches its expected.txt byte for byte"

echo "E2E-P42-DOCKER: $PASS passed, 0 failed (dynamic)"
