#!/bin/bash
# E2E-P44-HTTP-HEADERS: http 源的请求头（决策 90）
#
# 要证伪的是"spec 里的 headers 真的上了线"，而且证明的方式是**对端视角**：
# 夹具服务（scripts/http_fixture_server.py）按 PostgREST 的行为办事——缺
# `Accept-Profile: ia_csc` 就 404，并把它**实际收到的头**记进日志，门禁断言那份日志。
#
#   1  不给 headers：请求照发，服务端 404，管道按名失败（不是静默空跑）
#   2  给 headers：拿到 200 的 JSON 数组，管道把它当记录处理（决策流出现）
#   3  **服务端**日志里确实有 `Accept-Profile: ia_csc`（断言对端看到的，不断言客户端的意愿）
#   4  interval_ms 生效：服务端收到 ≥2 次请求（轮询而不是只取一次）
#   5  请求头的注入在 **spec 校验期**就被拒（CR/LF 进不了请求行），且在
#      wbtest 里另有两处钉住（字节形状与排序确定性）
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

EXE="${MOONFLUX_EXE:-$ROOT/_build/native/debug/build/apps/cli/cli.exe}"
WORK="$(mktemp -d /tmp/moonflux-p44.XXXXXX)"
PORT="${MOONFLUX_P44_PORT:-18521}"
PASS=0
SERVER_PID=""

fail() {
  echo "E2E-P44-HTTP-HEADERS FAIL: $*" >&2
  [ -f "$WORK/server.log" ] && tail -3 "$WORK/server.log" >&2
  exit 1
}
pass() { echo "E2E-P44-HTTP-HEADERS PASS: $*"; PASS=$((PASS + 1)); }
cleanup() {
  [ -n "$SERVER_PID" ] && kill -9 "$SERVER_PID" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

[ -x "$EXE" ] || { echo "missing $EXE (build first)" >&2; exit 1; }
command -v python3 > /dev/null 2>&1 || fail "python3 is required for the fixture server"

# 应答形状与真实 feed 同形（一条记录，字段名一致）
cat > "$WORK/body.json" <<'JSON'
[{"node_name":"CN_进水COD","var_value":1121.238403,"ts":"2026-10-14T04:16:00.520788+08:00","var_quality":192,"data_status":"正常"}]
JSON
: > "$WORK/requests.jsonl"

python3 "$ROOT/scripts/http_fixture_server.py" --port "$PORT" --body "$WORK/body.json" \
  --log "$WORK/requests.jsonl" --require "Accept-Profile=ia_csc" > "$WORK/server.log" 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 60); do
  grep -q "fixture server on" "$WORK/server.log" 2>/dev/null && break
  sleep 0.1
done
grep -q "fixture server on" "$WORK/server.log" || { cat "$WORK/server.log"; fail "the fixture server did not start"; }

spec_with() { # $1 = headers json fragment, $2 = spec path, $3 = topic suffix
  cat > "$2" <<JSON
{
  "apiVersion": "moonflux.io/v1alpha1",
  "kind": "Pipeline",
  "metadata": { "name": "p44-$3" },
  "spec": {
    "source": { "type": "http", "url": "http://127.0.0.1:$PORT/value",
                "interval_ms": 200$1 },
    "topic": { "name": "p44-$3-polls" },
    "state": { "topic": "p44-$3-state" },
    "transforms": [
      { "type": "wasm",
        "module": "$ROOT/_build/wasm/debug/build/apps/operator-keyconst/operator-keyconst.wasm",
        "config": { "key": "CN_进水COD" } },
      { "type": "wasm",
        "module": "$ROOT/_build/wasm/debug/build/apps/operator-stuck/operator-stuck.wasm",
        "config": { "window_minutes": 5, "notice_minutes": 5, "alarm_minutes": 10 } }
    ],
    "sink": { "type": "stdout" }
  }
}
JSON
}

# ---- 1. without the header the peer refuses ----------------------------
spec_with "" "$WORK/spec-noheaders.json" noheaders
"$EXE" pipeline run --data-dir "$WORK/d-noh" --spec "$WORK/spec-noheaders.json" \
  > "$WORK/out-noh.txt" 2> "$WORK/err-noh.txt" &
RUN=$!
sleep 3
kill -9 $RUN 2>/dev/null
grep -q "404" "$WORK/err-noh.txt" ||
  { tail -3 "$WORK/err-noh.txt"; fail "1: the missing header was not reported as a 404"; }
[ -s "$WORK/out-noh.txt" ] && fail "1: records came out of a refused request"
pass "1. 不给 headers：服务端按 PostgREST 的行为 404，管道按名失败（不静默空跑）"

# ---- 2/3/4. with the header: records flow, and the PEER saw it ---------
REQS_BEFORE=$(wc -l < "$WORK/requests.jsonl" | tr -d ' ')
spec_with ', "headers": { "Accept-Profile": "ia_csc" }' "$WORK/spec-headers.json" headers
"$EXE" pipeline run --data-dir "$WORK/d-h" --spec "$WORK/spec-headers.json" \
  > "$WORK/out-h.txt" 2> "$WORK/err-h.txt" &
RUN=$!
sleep 3
kill -9 $RUN 2>/dev/null
sleep 0.5
[ -s "$WORK/out-h.txt" ] || { tail -3 "$WORK/err-h.txt"; fail "2: no decision came out with the header set"; }
grep -q '"verdict"' "$WORK/out-h.txt" || { cat "$WORK/out-h.txt"; fail "2: the output is not a decision"; }
pass "2. 给 headers：拿到 200 的 JSON 数组，管道把它变成决策（$(head -1 "$WORK/out-h.txt" | cut -c1-60)…）"

python3 - "$WORK/requests.jsonl" <<'PY' || fail "3: the peer did not see the header"
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8") if l.strip()]
assert rows, "the fixture server logged no request at all"
seen = [r["headers"].get("Accept-Profile") for r in rows]
assert "ia_csc" in seen, f"Accept-Profile never arrived: {seen}"
print(f"server saw Accept-Profile={set(seen)} over {len(rows)} request(s)", file=sys.stderr)
PY
pass "3. **对端**日志里确实收到了 Accept-Profile: ia_csc（断言服务端看到的）"

REQS_AFTER=$(wc -l < "$WORK/requests.jsonl" | tr -d ' ')
[ "$REQS_AFTER" -ge $((REQS_BEFORE + 2)) ] ||
  fail "4: interval_ms did not poll (requests $REQS_BEFORE -> $REQS_AFTER)"
pass "4. interval_ms 生效：对端收到 $((REQS_AFTER - REQS_BEFORE)) 次请求（轮询，不是只取一次）"

# ---- 5. injection is refused at spec validation ------------------------
python3 - "$ROOT" "$WORK" <<'PY' || fail "5: a CR/LF header value was accepted by the spec"
import json, pathlib, subprocess, sys
root, work = sys.argv[1], sys.argv[2]
bad = {
    "apiVersion": "moonflux.io/v1alpha1", "kind": "Pipeline",
    "metadata": {"name": "p44-evil"},
    "spec": {"source": {"type": "http", "url": "http://127.0.0.1:1/x",
                        "headers": {"Accept-Profile": "a\r\nX-Evil: 1"}},
             "topic": {"name": "t"}, "transforms": [], "sink": {"type": "stdout"}},
}
path = pathlib.Path(work, "spec-evil.json")
path.write_text(json.dumps(bad), encoding="utf-8")
exe = f"{root}/_build/native/debug/build/apps/cli/cli.exe"
out = subprocess.run([exe, "pipeline", "plan", "-f", str(path)],
                     capture_output=True, text=True)
if out.returncode == 0:
    print(out.stdout, file=sys.stderr)
    sys.exit(1)
if "injection" not in (out.stdout + out.stderr):
    print(out.stdout + out.stderr, file=sys.stderr)
    sys.exit(1)
PY
pass "5. 请求头注入在 spec 校验期被拒（CR/LF 进不了请求行，错误按名说明）"

echo "E2E-P44-HTTP-HEADERS: $PASS passed, 0 failed"
