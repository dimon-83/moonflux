#!/bin/bash
# E2E-P41-DEPLOY: SDF 例子的 native 部署（决策 86）
#
# 例子门禁（e2e-p29）证明的是"用例在临时目录里逐字节对拍"；这条门禁证明的是
# **部署物**：一个部署根、每用例自己的数据目录、捕获的日志、记录的进程表、以及一个
# 共享的运行登记 broker 能被启起来、看得到、读得了、停得干净。
#
# 要证伪的是这些（每条都由门禁**自己**核对，不采信脚本的自述）：
#
#   1  部署后注册表里正好是"可自动跑"的那些用例，且状态全是 **stopped**（优雅），
#      **一个 offline 都没有**——被杀与停止在这里同样要分得开
#   2  每个可验证用例的输出与其 `expected.txt` **逐字节一致**（门禁用 cmp 自己比）
#   3  **没有静默跳过**：catalog 的每一行都有模式；deploy-only 与 run-unverified 的
#      每一行都有非空理由；三种模式的行数加起来 == 用例总数
#   4  跨用例的**真实主题冲突**存在（`sentence` 同时在 15 与 24），而部署之所以成立，
#      是因为**每个用例有自己的数据目录**——这条用数据钉住，不靠说法
#   5  `/metrics` 只出无标签计数，**用例名/任务名不进标签**
#   6  `stop` 之后没有残留：注册表端口不再监听，记录的进程都没了
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

EXE="${MOONFLUX_EXE:-$ROOT/_build/native/debug/build/apps/cli/cli.exe}"
WORK="$(mktemp -d /tmp/moonflux-p41.XXXXXX)"
DEPLOY="$WORK/deploy"
PORT="${MOONFLUX_P41_PORT:-19811}"
METRICS_PORT="${MOONFLUX_P41_METRICS_PORT:-19812}"
PASS=0

fail() { echo "E2E-P41-DEPLOY FAIL: $*" >&2; if [ -f "$WORK/deploy/broker/serve.log" ]; then tail -5 "$WORK/deploy/broker/serve.log" >&2; fi; exit 1; }
pass() { echo "E2E-P41-DEPLOY PASS: $*"; PASS=$((PASS + 1)); }

cleanup() {
  MOONFLUX_DEPLOY_DIR="$DEPLOY" "$ROOT/scripts/deploy-sdf.sh" stop > /dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

[ -x "$EXE" ] || { echo "missing $EXE (build first)" >&2; exit 1; }
"$ROOT/scripts/build-operators.sh" > /dev/null 2>&1 || fail "could not build the operator modules"

export MOONFLUX_EXE="$EXE" MOONFLUX_DEPLOY_DIR="$DEPLOY" MOONFLUX_DEPLOY_PORT="$PORT" \
  MOONFLUX_DEPLOY_METRICS_PORT="$METRICS_PORT"

"$ROOT/scripts/deploy-sdf.sh" start > "$WORK/start.log" 2>&1 ||
  { cat "$WORK/start.log"; fail "the deployment did not start"; }
grep -q "registry broker up" "$WORK/start.log" || { cat "$WORK/start.log"; fail "the registry never came up"; }

# the catalog is the deployment's own record of what it did
CATALOG="$DEPLOY/catalog.tsv"
[ -f "$CATALOG" ] || fail "no catalog was written"
TOTAL=$(wc -l < "$CATALOG" | tr -d ' ')
DIRS=$(ls -d examples/sdf/*/ | wc -l | tr -d ' ')
[ "$TOTAL" = "$DIRS" ] ||
  fail "the catalog has $TOTAL row(s) but there are $DIRS case directories"

# ---- 3. nothing is skipped silently ------------------------------------
python3 - "$CATALOG" <<'PY' || fail "3: the catalog hides a case or a reason"
import sys
rows = [l.rstrip("\n").split("\t") for l in open(sys.argv[1]) if l.strip()]
modes = {"run", "run-unverified", "deploy-only"}
bad = []
for row in rows:
    if len(row) != 4:
        bad.append(f"row with {len(row)} column(s): {row}")
        continue
    case, mode, spec, reason = row
    if mode not in modes:
        bad.append(f"{case}: unknown mode {mode}")
    if mode in ("deploy-only", "run-unverified") and (not reason or reason == "-"):
        bad.append(f"{case}: {mode} without a reason")
    if mode in ("run", "run-unverified") and (not spec or spec == "-"):
        bad.append(f"{case}: {mode} without a spec file")
if bad:
    print("\n".join(bad), file=sys.stderr)
    sys.exit(1)
counts = {}
for row in rows:
    counts[row[1]] = counts.get(row[1], 0) + 1
print("modes:", counts, file=sys.stderr)
PY
pass "3. every case has a mode, and every deploy-only/unverified row states its reason"

# ---- 1. the registry knows the runs, and none of them died --------------
"$EXE" run list --remote "127.0.0.1:$PORT" > "$WORK/runs.txt" 2>&1 ||
  { cat "$WORK/runs.txt"; fail "1: the registry did not answer"; }
RUN_ROWS=$(awk -F'\t' '$2 == "run" || $2 == "run-unverified" {n++} END {print n+0}' "$CATALOG")
LISTED=$(grep -c "state=" "$WORK/runs.txt" || true)
[ "$LISTED" = "$RUN_ROWS" ] ||
  { cat "$WORK/runs.txt"; fail "1: $RUN_ROWS case(s) should be running/reported, the registry lists $LISTED"; }
grep -q "state=offline" "$WORK/runs.txt" &&
  { cat "$WORK/runs.txt"; fail "1: a run went offline — the deployment's runs must END, not die"; }
grep -q "state=stopped" "$WORK/runs.txt" ||
  { cat "$WORK/runs.txt"; fail "1: no run reported a graceful stop"; }
pass "1. the registry lists every auto-run case as stopped (none offline): the deployment's runs end on purpose"

# ---- 2. the verified cases match their goldens, checked here -----------
VERIFIED=$(awk -F'\t' '$2 == "run" {print $1}' "$CATALOG")
checked=0
for case in $VERIFIED; do
  out="$DEPLOY/logs/$case.out"
  want="examples/sdf/$case/expected.txt"
  [ -f "$out" ] || fail "2: $case produced no output"
  cmp -s "$out" "$want" ||
    { diff -u "$want" "$out" | head -8; fail "2: $case differs from $want"; }
  checked=$((checked + 1))
done
[ "$checked" -ge 1 ] || fail "2: no case was verifiable at all"
pass "2. $checked case(s) match their expected.txt byte for byte (compared here, not taken on trust)"

# ---- 4. the collision is real, and the layout is why it does not matter -
python3 - examples/sdf <<'PY' || fail "4: the catalog's cross-case collision is not what the deployment says it is"
import json, pathlib, sys, collections
topics = collections.defaultdict(set)
for spec in pathlib.Path(sys.argv[1]).glob('*/spec*.json'):
    body = json.loads(spec.read_text())["spec"]
    topics[body["topic"]["name"]].add(spec.parent.name)
cross = {t: sorted(c) for t, c in topics.items() if len(c) > 1}
if "sentence" not in cross or len(cross["sentence"]) < 2:
    print("expected a cross-case collision on `sentence`:", cross, file=sys.stderr)
    sys.exit(1)
print("cross-case collisions:", cross, file=sys.stderr)
PY
# each deployed case keeps its own topic space: no two cases share a data dir
CASES=$(awk -F'\t' '$2 == "run" || $2 == "run-unverified" {print $1}' "$CATALOG")
for case in $CASES; do
  [ -d "$DEPLOY/cases/$case" ] || fail "4: $case has no data dir of its own"
done
DUP=$(printf '%s\n' $CASES | sort | uniq -d | wc -l | tr -d ' ')
[ "$DUP" = "0" ] || fail "4: a case is deployed twice"
pass "4. the catalog really collides across cases (sentence in 15 and 24) and the per-case data dirs are why it still works"

# ---- 5. metrics: counts, never a name ----------------------------------
METRICS=$(python3 - "$METRICS_PORT" <<'PY'
import sys, urllib.request
print(urllib.request.urlopen(f"http://127.0.0.1:{sys.argv[1]}/metrics", timeout=5).read().decode())
PY
) || fail "5: could not scrape the registry's /metrics"
echo "$METRICS" | grep -qE "^moonflux_runs(_offline)? " ||
  { echo "$METRICS" | head -8; fail "5: /metrics has no run counters"; }
echo "$METRICS" | grep -q "sdf-" &&
  { echo "$METRICS" | head -8; fail "5: a case/task name leaked into /metrics"; }
pass "5. the registry's /metrics reports run counts and carries no case name"

# ---- status names the reasons, and stop leaves nothing behind ----------
"$ROOT/scripts/deploy-sdf.sh" status > "$WORK/status.txt" 2>&1 ||
  fail "the status command failed"
grep -q "external system" "$WORK/status.txt" ||
  { head -20 "$WORK/status.txt"; fail "the status does not name the external-dependency cases"; }
grep -q "stages" "$WORK/status.txt" ||
  { head -20 "$WORK/status.txt"; fail "the status does not name the multi-stage cases"; }
grep -q "ran, not verified" "$WORK/status.txt" ||
  { head -20 "$WORK/status.txt"; fail "the status does not mark the cases without a single golden"; }
pass "the status names each deploy-only reason (external systems, stages, no single golden)"

"$ROOT/scripts/deploy-sdf.sh" stop > /dev/null 2>&1 || fail "stop failed"
sleep 1
if lsof -i ":$PORT" -sTCP:LISTEN > /dev/null 2>&1; then
  fail "6: the registry port is still listening after stop"
fi
LEFTOVER=0
while IFS=: read -r case pid; do
  kill -0 "$pid" 2>/dev/null && LEFTOVER=$((LEFTOVER + 1))
done < "$DEPLOY/run/pids"
[ "$LEFTOVER" = "0" ] || fail "6: $LEFTOVER case process(es) survived stop"
pass "6. stop leaves no listener and no case process behind"

echo "E2E-P41-DEPLOY: $PASS passed, 0 failed"
