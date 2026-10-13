#!/bin/bash
# E2E-P40-PANELS: 任务清单与运行面板（P37-3b，决策 85）
#
# 这两块面板要 broker 往返，所以门禁必须**真的连上去**，而不是比对字符串常量：
#
#   1  **同一份数据，两个宿主**：node 用**页面加载的那个内核产物**建帧、连 broker、
#      收应答、解码；结果与 CLI 的 `pipeline list --remote` / `run list` **逐字段一致**
#      （任务名/主题/变换数；run id/任务/状态/pid/进度）
#   2  **按"问什么"读应答**：broker 对成功命令一律回 `CMD_OK`，所以内核按 request id
#      记住自己问了什么。这条腿专门覆盖那个不可推断的歧义（P27 的教训：靠载荷形状猜）
#   3  页面确实用了这两个导出，并且 run-log 按钮取的是 `<task>.run-log` 主题
#      ——**浏览器不拥有日志**，执行记录永远是读 broker 上的运行日志
#   4  面板渲染**只吃内核解码出来的东西**（`kind === "task-set"` / `"runs"`），
#      **不做像素门禁**（浏览器阶段由 agent/人驱动，与 p4-editor/p27 同形）
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

EXE="${MOONFLUX_EXE:-$ROOT/_build/native/debug/build/apps/cli/cli.exe}"
WORK="$(mktemp -d /tmp/moonflux-p40.XXXXXX)"
SC_PORT="${MOONFLUX_P40_SC_PORT:-19641}"
NODE_PORT="${MOONFLUX_P40_NODE_PORT:-19642}"
PIDS=""
PASS=0

fail() { echo "E2E-P40-PANELS FAIL: $*" >&2; exit 1; }
pass() { echo "E2E-P40-PANELS PASS: $*"; PASS=$((PASS + 1)); }

cleanup() {
  for pid in $PIDS; do kill -9 "$pid" 2>/dev/null; done
  wait 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

[ -x "$EXE" ] || { echo "missing $EXE (build first)" >&2; exit 1; }
command -v node > /dev/null 2>&1 || fail "node is required to run the page's kernel artifact"
JS=$(ls "$ROOT"/_build/js/*/build/apps/editor-kernel/editor-kernel.js 2>/dev/null | head -1)
[ -n "$JS" ] || fail "editor-kernel.js is missing (moon build --target js apps/editor-kernel)"
cp "$JS" "$WORK/kernel.mjs"

wait_listen() { local port="$1" tenths="${2:-80}" i=0
  while [ "$i" -lt "$tenths" ]; do
    lsof -i ":$port" -sTCP:LISTEN > /dev/null 2>&1 && return 0
    sleep 0.1; i=$((i + 1))
  done
  return 1
}

SC="127.0.0.1:$SC_PORT"
mkdir -p "$WORK/sc"
"$EXE" sc --listen "$SC" --data-dir "$WORK/sc" > "$WORK/sc.log" 2>&1 &
PIDS="$PIDS $!"
wait_listen "$SC_PORT" || { cat "$WORK/sc.log"; fail "the control plane did not start"; }

# a two-task set and one live run: the panels need something to show
cat > "$WORK/a.json" <<'JSON'
{"apiVersion":"moonflux.io/v1alpha1","kind":"Pipeline","metadata":{"name":"panel-a"},
 "spec":{"source":{"type":"topic","name":"pa","from":"beginning"},"topic":{"name":"pa"},
 "transforms":[],"sink":{"type":"stdout"}}}
JSON
cat > "$WORK/b.json" <<'JSON'
{"apiVersion":"moonflux.io/v1alpha1","kind":"Pipeline","metadata":{"name":"panel-b"},
 "spec":{"source":{"type":"topic","name":"pb","from":"beginning"},"topic":{"name":"pb"},
 "transforms":[{"type":"expr","expr":"upper(value)"}],"sink":{"type":"stdout"}}}
JSON
"$EXE" pipeline apply --remote "$SC" -f "$WORK/a.json" > /dev/null 2>&1 || fail "applying panel-a failed"
"$EXE" pipeline apply --remote "$SC" -f "$WORK/b.json" > /dev/null 2>&1 || fail "applying panel-b failed"
"$EXE" topic create --name panel-a.run-log --partitions 1 --replication-factor 1 --remote "$SC" > /dev/null 2>&1 ||
  fail "declaring the run log failed"
# a declared topic still needs a NODE to host it: a run log that is declared but
# unhosted has no leader, and the runner says so and does not register (the
# boundary leg in e2e-p38 covers that side; here we want a working panel)
"$EXE" spu --id n1 --listen "127.0.0.1:$NODE_PORT" --data-dir "$WORK/n1" --sc "$SC" \
  > "$WORK/n1.log" 2>&1 &
PIDS="$PIDS $!"
wait_listen "$NODE_PORT" || { cat "$WORK/n1.log"; fail "the data node did not start"; }
LEADER=""
for _ in $(seq 1 100); do
  LEADER=$("$EXE" cluster leader --topic panel-a.run-log --remote "$SC" 2>/dev/null || true)
  [ -n "$LEADER" ] && break
  sleep 0.1
done
[ -n "$LEADER" ] || { cat "$WORK/sc.log"; fail "the run log got no leader"; }
"$EXE" pipeline run --data-dir "$WORK/runner" --spec "$WORK/a.json" \
  --state-remote "$SC" > "$WORK/run.out" 2> "$WORK/run.err" &
RUN_PID=$!
PIDS="$PIDS $RUN_PID"
for _ in $(seq 1 60); do
  "$EXE" run list --remote "$SC" 2>/dev/null | grep -q "task=panel-a" && break
  sleep 0.1
done
"$EXE" run list --remote "$SC" | grep -q "task=panel-a" ||
  { cat "$WORK/run.err"; "$EXE" run list --remote "$SC"; fail "the run did not register"; }

# ---- the probe: the page's kernel builds the frame, opens the socket, decodes
cat > "$WORK/panels.mjs" <<'JS'
// Drives the page's kernel artifact against a real broker: same frames, same
// reply decoding. The only thing this adds is a TCP socket and the frame
// splitter, because a browser has WebSocket and node has net.
import net from "node:net";

const [kernelPath, addr, which] = process.argv.slice(2);
const kernel = await import(kernelPath);
const [host, port] = addr.split(":");

const build = which === "tasks" ? kernel.mf_editor_task_list : kernel.mf_editor_run_list;
const request = build();

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
    } else {
      out = kernel.mf_editor_feed(new Uint8Array(frame));
      sock.end();
    }
  }
});
sock.on("close", () => {
  if (out === null) {
    console.error("no reply arrived");
    process.exit(1);
  }
  process.stdout.write(out + "\n");
});
sock.on("error", (e) => { console.error(String(e)); process.exit(1); });
JS

node "$WORK/panels.mjs" "$WORK/kernel.mjs" "$SC" tasks > "$WORK/tasks.kernel" 2> "$WORK/tasks.err" ||
  { cat "$WORK/tasks.err"; fail "1: the page's kernel could not read the task set"; }
node "$WORK/panels.mjs" "$WORK/kernel.mjs" "$SC" runs > "$WORK/runs.kernel" 2> "$WORK/runs.err" ||
  { cat "$WORK/runs.err"; fail "1: the page's kernel could not read the run table"; }

# ---- 1. the two hosts see the same data ---------------------------------
"$EXE" pipeline list --remote "$SC" > "$WORK/tasks.cli" 2>&1 ||
  fail "1: the CLI could not list the task set"
python3 - "$WORK/tasks.kernel" "$WORK/tasks.cli" <<'PY' || fail "1: the page and the CLI disagree about the task set"
import json, re, sys
kernel = json.load(open(sys.argv[1]))
cli_lines = [l for l in open(sys.argv[2]).read().splitlines() if l and not l.startswith("cluster_revision=")]
# `panel-a\ttopic=pa\ttransforms=0\tfunctions=-\tapplied_at=...`
cli = []
for line in cli_lines:
    parts = line.split("\t")
    fields = dict(p.split("=", 1) for p in parts[1:])
    cli.append((parts[0], fields["topic"], int(fields["transforms"])))
page = [(t["name"], t["topic"], t["transforms"]) for t in kernel["tasks"]]
if page != cli:
    print("page:", page, file=sys.stderr)
    print("cli :", cli, file=sys.stderr)
    sys.exit(1)
PY
pass "1. the page's kernel and the CLI agree on the task set (name, topic, transforms)"

"$EXE" run list --remote "$SC" > "$WORK/runs.cli" 2>&1 || fail "1: the CLI could not list the runs"
python3 - "$WORK/runs.kernel" "$WORK/runs.cli" <<'PY' || fail "1: the page and the CLI disagree about the runs"
import json, sys
kernel = json.load(open(sys.argv[1]))
cli = []
for line in open(sys.argv[2]).read().splitlines():
    if not line:
        continue
    parts = line.split("\t")
    fields = dict(p.split("=", 1) for p in parts[1:])
    cli.append((parts[0], fields["task"], fields["state"], fields["pid"], fields["progress"]))
page = []
for run in kernel["runs"]:
    progress = "-" if run["progress"] < 0 else str(run["progress"])
    page.append((run["id"], run["task"], run["state"], str(run["pid"]), progress))
if page != cli:
    print("page:", page, file=sys.stderr)
    print("cli :", cli, file=sys.stderr)
    sys.exit(1)
if not any(r[2] == "running" for r in page):
    print("no running run in the table:", page, file=sys.stderr)
    sys.exit(1)
PY
pass "1. the page's kernel and the CLI agree on the run table (id, task, state, pid, progress)"

# ---- 2. the reply is read by what was asked, not by its shape -----------
# Both replies arrive as CMD_OK. Feeding a RUN LIST payload to a session that
# asked for the TASK SET must not silently render run rows (and vice versa).
python3 - "$WORK/tasks.kernel" "$WORK/runs.kernel" <<'PY' || fail "2: the two replies are not told apart by the question"
import json, sys
tasks = json.load(open(sys.argv[1]))
runs = json.load(open(sys.argv[2]))
assert tasks["kind"] == "task-set", tasks["kind"]
assert runs["kind"] == "runs", runs["kind"]
assert "runs" not in tasks and "tasks" not in runs, (tasks.keys(), runs.keys())
assert tasks["revision"] >= 2, tasks["revision"]
PY
pass "2. a task-set reply and a run-list reply are told apart by the request id, not by their bytes"

# ---- 3. the page uses these exports, and the log comes from the broker --
grep -q "mf_editor_task_list" web/editor/index.html ||
  fail "3: the page does not ask for the task set through the kernel"
grep -q "mf_editor_run_list" web/editor/index.html ||
  fail "3: the page does not ask for the runs through the kernel"
grep -q 'run.task}.run-log' web/editor/index.html ||
  fail "3: the run-log button does not fetch <task>.run-log"
grep -q 'kernel.mf_editor_fetch' web/editor/index.html ||
  fail "3: the run log is not fetched through the kernel's fetch path"
pass "3. the page asks for both panels through the kernel and reads run logs from the broker"

# ---- 4. the panels render only what the kernel decoded ------------------
grep -q 'decoded.kind === "task-set"' web/editor/index.html ||
  fail "4: the tasks panel does not route on the kernel's decoded kind"
grep -q 'decoded.kind === "runs"' web/editor/index.html ||
  fail "4: the runs panel does not route on the kernel's decoded kind"
grep -q "function renderTasks" web/editor/index.html || fail "4: no task renderer"
grep -q "function renderRuns" web/editor/index.html || fail "4: no run renderer"
# the page's expected ABI must be the number the kernel actually reports (the
# two new exports are why it moved to 4)
KERNEL_ABI=$(node --input-type=module -e "const k = await import('$WORK/kernel.mjs'); console.log(k.mf_editor_abi_version())")
PAGE_ABI=$(sed -n 's/.*this page expects \([0-9]*\);.*/\1/p' web/editor/index.html | head -1)
[ "$PAGE_ABI" = "$KERNEL_ABI" ] ||
  fail "4: the page expects ABI $PAGE_ABI but the kernel reports $KERNEL_ABI"
pass "4. both panels render the kernel's decoded kinds (no pixel gate: the browser phase is agent/human driven)"

echo "E2E-P40-PANELS: $PASS passed, 0 failed"
