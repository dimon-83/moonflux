#!/bin/bash
# E2E-P39-CONSOLE: 控制台的视图模型（P37-3，决策 84）
#
# 控制台要渲染"编译后的拓扑"，而它**不得自己推导拓扑**（P4：编辑器渲染 spec 与编译器，
# 绝不定义第二个真相）。所以模型来自内核导出，这条门禁证伪的是"两个宿主显示同一张图"：
#
#   1  **跨宿主逐字节一致**：CLI 的 `pipeline view -f spec.json` 与**页面加载的那个 JS 产物**
#      （`editor-kernel.js`，在 node 里直接调用 `mf_editor_view`）输出**完全相同**——
#      不是"同一个函数所以应该一样"，而是把真产物跑起来比字节
#   2  **节点就是编译器的进程**：模型的 node id 序列 == `pipeline plan` 打出的 processes
#      （两条不同的输出路径，做结构对拍）
#   3  边的规则可证伪：连接器源 `source-runner->broker`；主题源多一条 `broker->source-runner`
#      （接力）；读路径 `broker->transform-0->...->sink`，空链是 `broker->sink`
#   4  模型带 `model` 版本号与 `runnable`（能不能在当前运行时跑，P2 的能力规则），
#      页面断言 ABI 版本（3）——**不做像素门禁**：浏览器阶段由 agent/人驱动，
#      与 e2e-p4-editor / e2e-p27-editor-functions 同形
#   5  坏 spec 返回**结构化错误**而不是崩（页面据此显示拒绝理由）
#
# 如实边界（P37-3b，尚未落地）：任务清单与执行记录面板需要 broker 往返（两个新的内核帧
# 构造/解码函数），本门禁只覆盖拓扑面板这条**不需要 broker** 的路径。
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

EXE="${MOONFLUX_EXE:-$ROOT/_build/native/debug/build/apps/cli/cli.exe}"
WORK="$(mktemp -d /tmp/moonflux-p39.XXXXXX)"
PASS=0

fail() { echo "E2E-P39-CONSOLE FAIL: $*" >&2; exit 1; }
pass() { echo "E2E-P39-CONSOLE PASS: $*"; PASS=$((PASS + 1)); }

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

[ -x "$EXE" ] || { echo "missing $EXE (build first)" >&2; exit 1; }
command -v node > /dev/null 2>&1 || fail "node is required to run the page's kernel artifact"

# the artifact the PAGE loads, run as a module in node. Copied to .mjs so node
# treats it as ESM (the page imports it as a module; a bare .js is CommonJS by
# default, which is a node convention, not a moonflux one).
JS=$(ls "$ROOT"/_build/js/*/build/apps/editor-kernel/editor-kernel.js 2>/dev/null | head -1)
[ -n "$JS" ] || fail "editor-kernel.js is missing (moon build --target js apps/editor-kernel)"
cp "$JS" "$WORK/kernel.mjs"

cat > "$WORK/apply.mjs" <<'JS'
// calls the page's kernel artifact exactly as the page does
const kernel = await import(process.argv[2]);
const spec = process.argv[3];
// console.log, not write: the CLI prints the model with a trailing newline, and
// the comparison below is a byte comparison (the first run flagged the missing
// newline, which is exactly the kind of difference a byte comparison should
// refuse to paper over)
console.log(kernel.mf_editor_view(spec));
JS

# fixtures: connector source / topic source / transform chain / no transforms
cat > "$WORK/file.json" <<'JSON'
{"apiVersion":"moonflux.io/v1alpha1","kind":"Pipeline","metadata":{"name":"file-task"},
 "spec":{"source":{"type":"file","path":"a.txt"},"topic":{"name":"events"},
 "transforms":[],"sink":{"type":"stdout"}}}
JSON
cat > "$WORK/chain.json" <<'JSON'
{"apiVersion":"moonflux.io/v1alpha1","kind":"Pipeline","metadata":{"name":"chain-task"},
 "spec":{"source":{"type":"file","path":"a.txt"},"topic":{"name":"events"},
 "transforms":[{"type":"expr","expr":"upper(value)"},{"type":"wasm","module":"m.wasm","config":{}}],
 "sink":{"type":"topic","name":"out"}}}
JSON
cat > "$WORK/relay.json" <<'JSON'
{"apiVersion":"moonflux.io/v1alpha1","kind":"Pipeline","metadata":{"name":"relay-task"},
 "spec":{"source":{"type":"topic","name":"events","from":"beginning"},"topic":{"name":"events"},
 "transforms":[],"sink":{"type":"stdout"}}}
JSON

# ---- 1. the CLI and the page's kernel artifact agree byte for byte -------
for name in file chain relay; do
  "$EXE" pipeline view -f "$WORK/$name.json" > "$WORK/$name.cli" 2> "$WORK/$name.err" ||
    { cat "$WORK/$name.err"; fail "1: pipeline view failed for $name"; }
  node "$WORK/apply.mjs" "$WORK/kernel.mjs" "$(cat "$WORK/$name.json")" > "$WORK/$name.js" ||
    fail "1: the page's kernel artifact failed for $name"
  cmp -s "$WORK/$name.cli" "$WORK/$name.js" ||
    { diff "$WORK/$name.cli" "$WORK/$name.js" | head -10; fail "1: the CLI and the page disagree on $name"; }
done
pass "1. the CLI's view model and the page's kernel artifact are byte-identical for three shapes"

# ---- 2. the nodes ARE the compiler's processes -------------------------
for name in file chain relay; do
  "$EXE" pipeline plan -f "$WORK/$name.json" > "$WORK/$name.plan" 2>&1 ||
    fail "2: pipeline plan failed for $name"
  python3 - "$WORK/$name.cli" "$WORK/$name.plan" <<'PY' || fail "2: the model's nodes are not the compiler's processes ($name)"
import json, re, sys
model = json.load(open(sys.argv[1]))
plan = open(sys.argv[2]).read()
# `pipeline plan` prints "  <name> [<capability>] (<role>): <detail>"
plan_names = re.findall(r"^  ([a-z0-9-]+) \[", plan, re.M)
model_ids = [n["id"] for n in model["nodes"]]
if model_ids != plan_names:
    print("model:", model_ids, file=sys.stderr)
    print("plan :", plan_names, file=sys.stderr)
    sys.exit(1)
PY
done
pass "2. the model's node order equals the processes the compiler prints (three shapes)"

# ---- 3. the edge rule, shape by shape ----------------------------------
python3 - "$WORK/file.cli" "$WORK/chain.cli" "$WORK/relay.cli" <<'PY' || fail "3: the edge rule does not hold"
import json, sys
def edges(path):
    return [f'{e["from"]}->{e["to"]}:{e["kind"]}' for e in json.load(open(path))["edges"]]
expected = {
    "file": ["source-runner->broker:append", "broker->sink-runner:consume"],
    "chain": ["source-runner->broker:append", "broker->transform-0:consume",
              "transform-0->transform-1:consume", "transform-1->sink-runner:consume"],
    "relay": ["broker->source-runner:read", "source-runner->broker:append",
              "broker->sink-runner:consume"],
}
for name, path in zip(["file", "chain", "relay"], sys.argv[1:4]):
    got = edges(path)
    if got != expected[name]:
        print(name, "got:", got, file=sys.stderr)
        print(name, "want:", expected[name], file=sys.stderr)
        sys.exit(1)
PY
pass "3. the edge rule holds for a connector source, a transform chain and a relay"

# ---- 4. the model carries its version, and the page asserts the ABI ----
python3 - "$WORK/chain.cli" <<'PY' || fail "4: the model has no version or runnable flag"
import json, sys
model = json.load(open(sys.argv[1]))
assert model["model"] == 1, model.get("model")
assert all("runnable" in n for n in model["nodes"]), "a node does not say whether it can run"
assert model["pipeline"] == "chain-task" and model["topic"] == "events"
PY
grep -q "mf_editor_view" web/editor/index.html ||
  fail "4: the page does not call the view-model export"
# the page's expected number must equal what the KERNEL reports: a literal here
# would have to be edited on every bump, and the invariant is what matters
KERNEL_ABI=$(node -e "const k = await import('$WORK/kernel.mjs'); console.log(k.mf_editor_abi_version())" 2>/dev/null ||
  node --input-type=module -e "const k = await import('$WORK/kernel.mjs'); console.log(k.mf_editor_abi_version())")
PAGE_ABI=$(sed -n 's/.*this page expects \([0-9]*\);.*/\1/p' web/editor/index.html | head -1)
[ -n "$PAGE_ABI" ] || fail "4: the page does not state the ABI it expects"
[ "$PAGE_ABI" = "$KERNEL_ABI" ] ||
  fail "4: the page expects ABI $PAGE_ABI but the kernel reports $KERNEL_ABI"
pass "4. the model is versioned, says what can run, and the page asserts the matching ABI"

# ---- 5. a bad spec is a structured refusal, not a crash ----------------
node "$WORK/apply.mjs" "$WORK/kernel.mjs" '{"apiVersion":"moonflux.io/v1alpha1"}' > "$WORK/bad.json" ||
  fail "5: the kernel crashed on an invalid spec"
python3 - "$WORK/bad.json" <<'PY' || fail "5: an invalid spec did not produce a structured error"
import json, sys
doc = json.load(open(sys.argv[1]))
assert "error" in doc and len(doc["error"]) > 0, doc
assert "path" in doc["error"][0], doc["error"][0]
PY
pass "5. an invalid spec comes back as a structured error the page can show"

echo "E2E-P39-CONSOLE: $PASS passed, 0 failed"
