#!/bin/bash
# E2E-P53-MANAGEMENT-PANEL: 管理面板（P37-5c，决策 111）
#
# 这块面板要 broker 往返，所以门禁**真的连上去**，而不是比对字符串常量（与
# p40-panels 同形，也是它的下半场）：用**页面加载的那个内核产物**建帧、连真 `sc`、
# 收应答、解码，再与 CLI 的 `task schedule --remote` **逐字段对拍**。
#
#   1  同一份数据两个宿主：内核解出的调度行与 CLI 的行**逐字段一致**
#      （task/target/owner/state/reason）
#   2  **pending 带原因**：目标 worker 不在的任务，行里必须写着为什么——
#      "没在跑"但没有"为什么"正是这张表要消除的沉默
#   3  **生命周期按钮发的是真命令**：`mf_editor_task_enabled` 的应答是**更新后的任务集**
#      （页面据此重渲染），且控制面的表真的变成 `disabled`
#   4  页面**只吃内核解码出来的东西**，并且用的是这两个导出（面板不会被静默删掉）
#
# 浏览器阶段（真的点按钮）与 p4-editor/p27 同形：agent/人驱动，不进步表。
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

EXE="${MOONFLUX_EXE:-$ROOT/_build/native/debug/build/apps/cli/cli.exe}"
WORK="$(mktemp -d /tmp/moonflux-p53.XXXXXX)"
SC_PORT="${MOONFLUX_P53_SC_PORT:-19741}"
METRICS_PORT="${MOONFLUX_P53_METRICS_PORT:-19742}"
PIDS=""
PASS=0

fail() { echo "E2E-P53-MANAGEMENT-PANEL FAIL: $*" >&2; exit 1; }
pass() { echo "E2E-P53-MANAGEMENT-PANEL PASS: $*"; PASS=$((PASS + 1)); }
cleanup() {
  for pid in $PIDS; do kill -9 "$pid" 2>/dev/null; done
  wait 2>/dev/null
  sleep 0.3
  rm -rf "$WORK"
}
trap cleanup EXIT

[ -x "$EXE" ] || { echo "missing $EXE (build first)" >&2; exit 1; }
command -v node > /dev/null 2>&1 || fail "node is required to run the page's kernel artifact"
JS=$(ls "$ROOT"/_build/js/*/build/apps/editor-kernel/editor-kernel.js 2>/dev/null | head -1)
[ -n "$JS" ] || fail "editor-kernel.js is missing (moon build --target js apps/editor-kernel)"
cp "$JS" "$WORK/kernel.mjs"

wait_listen() {
  local port="$1" tenths="${2:-80}" i=0
  while [ "$i" -lt "$tenths" ]; do
    lsof -i ":$port" -sTCP:LISTEN > /dev/null 2>&1 && return 0
    sleep 0.1; i=$((i + 1))
  done
  return 1
}
SC="127.0.0.1:$SC_PORT"
sched() { "$EXE" task schedule --remote "$SC" 2>/dev/null; }
wait_sched() {
  local pattern="$1" tenths="${2:-300}" i=0
  while [ "$i" -lt "$tenths" ]; do
    sched | grep -q "$pattern" && return 0
    sleep 0.1; i=$((i + 1))
  done
  return 1
}

# ---- a task set with something to see in every column -------------------
# live     : floating, so a worker picks it up -> running
# pinned   : pinned to a worker that does not exist -> pending WITH a reason
# off      : will be stopped through the panel's own verb
cat > "$WORK/set.json" <<'JSON'
{"pipelines":[
 {"pipeline":"live",
  "spec":{"apiVersion":"moonflux.io/v1alpha1","kind":"Pipeline","metadata":{"name":"live"},
   "spec":{"source":{"type":"topic","name":"in-live","from":"beginning"},"topic":{"name":"in-live"},
    "transforms":[],"sink":{"type":"stdout"}}}},
 {"pipeline":"pinned","target":"worker-zzz",
  "spec":{"apiVersion":"moonflux.io/v1alpha1","kind":"Pipeline","metadata":{"name":"pinned"},
   "spec":{"source":{"type":"topic","name":"in-pinned","from":"beginning"},"topic":{"name":"in-pinned"},
    "transforms":[],"sink":{"type":"stdout"}}}},
 {"pipeline":"off",
  "spec":{"apiVersion":"moonflux.io/v1alpha1","kind":"Pipeline","metadata":{"name":"off"},
   "spec":{"source":{"type":"topic","name":"in-off","from":"beginning"},"topic":{"name":"in-off"},
    "transforms":[],"sink":{"type":"stdout"}}}}
]}
JSON

"$EXE" sc --listen "127.0.0.1:$SC_PORT" --data-dir "$WORK/sc" \
  --metrics-listen "127.0.0.1:$METRICS_PORT" > "$WORK/sc.log" 2>&1 &
PIDS="$PIDS $!"
wait_listen "$SC_PORT" || { cat "$WORK/sc.log"; fail "the control plane did not start"; }
export MOONFLUX_EXE="$EXE"

# one worker, so "assigned/running" and "pending" can both be true at once
"$EXE" runner --data-dir "$WORK/runner" --control "$SC" --worker worker-a \
  > "$WORK/runner.out" 2> "$WORK/runner.err" &
PIDS="$PIDS $!"
sleep 2

"$EXE" pipeline apply -f "$WORK/set.json" --set --remote "$SC" > /dev/null 2>&1 ||
  fail "applying the task set to the cluster failed"

wait_sched "live	.*state=running" 400 ||
  { sched; cat "$WORK/runner.err"; fail "1: the worker never picked up the floating task"; }
wait_sched "pinned	.*state=pending" 200 ||
  { sched; fail "1: a task pinned to a missing worker is not pending"; }

# ---- the probe: the page's kernel builds the frame, opens the socket, decodes
cat > "$WORK/panel.mjs" <<'JS'
// Drives the page's kernel artifact against a real control plane: the same
// frames and the same reply decoding the page uses. What this adds over the page
// is a TCP socket and the frame splitter, because a browser has WebSocket and
// node has net.
import net from "node:net";

const [kernelPath, addr, mode, arg1, arg2] = process.argv.slice(2);
const kernel = await import(kernelPath);
const [host, port] = addr.split(":");

// the two management verbs, exactly as the panel calls them
const request = mode === "schedule"
  ? kernel.mf_editor_schedule()
  : kernel.mf_editor_task_enabled(arg1, arg2 === "true");

const sock = net.createConnection({ host, port: Number(port) });
let buffered = Buffer.alloc(0);
let stage = "welcome";
let out = null;

function frames() {
  // MFS: 'M' 'F' 'S' version cmd rid(u32) len(u32) payload
  const ready = [];
  while (buffered.length >= 13) {
    const len = buffered.readUInt32BE(9);
    if (buffered.length < 13 + len) break;
    ready.push(buffered.subarray(0, 13 + len));
    buffered = buffered.subarray(13 + len);
  }
  return ready;
}

sock.on("connect", () => sock.write(Buffer.from(kernel.mf_editor_hello())));
sock.on("data", (chunk) => {
  buffered = Buffer.concat([buffered, chunk]);
  for (const frame of frames()) {
    if (stage === "welcome") {
      stage = "reply";
      sock.write(Buffer.from(request));
    } else if (out === null) {
      out = kernel.mf_editor_feed(new Uint8Array(frame));
      sock.end();
    }
  }
});
sock.on("close", () => {
  if (out === null) { console.error("no reply arrived"); process.exit(1); }
  process.stdout.write(out + "\n");
});
sock.on("error", (e) => { console.error(String(e)); process.exit(1); });
JS

node "$WORK/panel.mjs" "$WORK/kernel.mjs" "$SC" schedule > "$WORK/schedule.kernel" 2> "$WORK/schedule.err" ||
  { cat "$WORK/schedule.err"; fail "1: the page's kernel could not read the schedule"; }

# ---- 1. the two hosts see the same table -------------------------------
sched > "$WORK/schedule.cli" 2>&1 ||
  fail "1: the CLI could not read the schedule"
python3 - "$WORK/schedule.kernel" "$WORK/schedule.cli" > "$WORK/schedule.diff" 2>&1 <<'PY' || fail "1: the page and the CLI disagree about the schedule ($(cat "$WORK/schedule.diff"))"
import json, sys
page = json.load(open(sys.argv[1]))
if page.get("kind") != "schedule":
    print(f"the kernel decoded kind={page.get('kind')!r}, not 'schedule'")
    sys.exit(1)
# the CLI's table prints "-" for an empty field (it is a tab-separated line for
# cut/grep), while the kernel hands the page an empty string. Normalise before
# comparing: the fact under test is the CONTENT, not how a text table spells
# "nothing" (this cost one debugging round - measured).
def norm(v):
    return "" if v == "-" else v
rows = {}
for line in open(sys.argv[2]).read().splitlines():
    if not line.strip():
        continue
    parts = line.split("\t")
    fields = dict(p.split("=", 1) for p in parts[1:])
    rows[parts[0]] = (fields["target"], norm(fields["owner"]), fields["state"], norm(fields["reason"]))
page_rows = {r["task"]: (r["target"], r["owner"], r["state"], r["reason"]) for r in page["rows"]}
if page_rows != rows:
    print("page:", page_rows)
    print("cli :", rows)
    sys.exit(1)
PY
pass "1. the page's kernel and the CLI agree on the schedule, field by field"

# ---- 2. pending carries its reason -------------------------------------
python3 - "$WORK/schedule.kernel" <<'PY' || fail "2: a pending row does not say why"
import json, sys
rows = json.load(open(sys.argv[1]))["rows"]
pending = [r for r in rows if r["state"] == "pending"]
if not pending:
    print("no pending row to check", file=sys.stderr); sys.exit(1)
for r in pending:
    if not r["reason"]:
        print(f"pending row {r['task']} has no reason", file=sys.stderr); sys.exit(1)
if not any("pin is a declaration" in r["reason"] for r in pending):
    print("the pending reason does not name the pin", file=sys.stderr); sys.exit(1)
PY
pass "2. pending 带原因（且明确指出：pin 是声明、不重分配）"

# ---- 3. the lifecycle button sends a real command ----------------------
node "$WORK/panel.mjs" "$WORK/kernel.mjs" "$SC" flip off false > "$WORK/flip.kernel" 2> "$WORK/flip.err" ||
  { cat "$WORK/flip.err"; fail "3: the page's kernel could not send the lifecycle verb"; }
python3 - "$WORK/flip.kernel" > "$WORK/flip.diff" 2>&1 <<'PY' || fail "3: the flip reply is not the acknowledgement the page expects ($(cat "$WORK/flip.diff"))"
import json, sys
reply = json.load(open(sys.argv[1]))
if reply.get("kind") != "task-set":
    print(f"reply kind={reply.get('kind')!r}, expected 'task-set'")
    sys.exit(1)
# The control plane answers a flip with the revision ALONE (document ""), which
# is why the kernel reports has_document=false and the page asks for the document
# separately. Asserting a task list here would be asserting a reply that does not
# exist - and the first version of this leg did exactly that.
if reply.get("has_document") is not False:
    print(f"has_document={reply.get('has_document')!r}, expected false (revision-only ack)")
    sys.exit(1)
if not isinstance(reply.get("revision"), (int, float)):
    print(f"the acknowledgement carries no revision: {reply!r}")
    sys.exit(1)
PY
wait_sched "off	.*state=disabled" 200 ||
  { sched; fail "3: the control plane's table did not become disabled after the flip"; }
pass "3. 生命周期按钮发的是真命令：应答是只带修订的确认（has_document=false），且控制面真的变成 disabled"

# ---- 4. the page uses the kernel, and renders only what it decoded -----
grep -q "mf_editor_schedule" web/editor/index.html ||
  fail "4: the page does not ask for the schedule through the kernel"
grep -q "mf_editor_task_enabled" web/editor/index.html ||
  fail "4: the lifecycle button does not send through the kernel"
grep -q 'decoded.kind === "schedule"' web/editor/index.html ||
  fail "4: the schedule panel does not route on the kernel's decoded kind"
grep -q "function renderSchedule" web/editor/index.html || fail "4: no schedule renderer"
# the reason column has to exist: a state without its why is the silence this
# panel removes
grep -q "r.reason" web/editor/index.html ||
  fail "4: the schedule panel does not render the reason"
# the page must not confuse "stop succeeded" with "there are no tasks"
grep -q "decoded.has_document" web/editor/index.html ||
  fail "4: the page does not distinguish a revision-only ack from a task set"
KERNEL_ABI=$(node --input-type=module -e "const k = await import('$WORK/kernel.mjs'); console.log(k.mf_editor_abi_version())")
grep -q "abi !== $KERNEL_ABI" web/editor/index.html ||
  fail "4: the page's expected ABI is not the kernel's ($KERNEL_ABI)"
pass "4. 页面只吃内核解码、用的是这两个导出、渲染了 reason、ABI 与内核一致（v${KERNEL_ABI}）"

echo "E2E-P53-MANAGEMENT-PANEL: $PASS passed, 0 failed"
