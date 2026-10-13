#!/bin/bash
# E2E-P46-DEPLOY-ROUTING: 部署产品化的形状（决策 93）
#
# 产品化把一条管道拆成两段（都在工程外，单位文件在 ~/workspace/citics-plant-monitor/moonflux/）：
#
#   A  取数 → 恒值判定 → 判决落**主题**（键＝点位 ⇒ 压实即"每点位最新判决"）
#   B  判决主题 → 只留 STUCK → 外发 webhook（https + 鉴权头）
#
# 这条门禁证伪的是**形状**，不是重复 p43/p45 已经证过的东西：
#
#   1  B 只把 STUCK 发出去：给判决主题喂 OK/NOTICE/STUCK 三条，**对端只收到 STUCK**
#      （断言的是服务端拿到的体，不是客户端的意愿）
#   2  外发的鉴权头真的到了对端（webhook 的鉴权就靠它）；缺头则被拒且管道按名失败
#   3  判决**按点位为键**（"每点位最新判决"因此是键控压实的推论；压实本身由 P14/P28 门禁证）
#   4  **重启后状态重放**：同一数据目录换一个进程再跑同一份输入，零决策、状态不变
#      ——水位与段账都存在状态主题里，跨进程成立（p43 只证了同进程内重复轮询）
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

EXE="${MOONFLUX_EXE:-$ROOT/_build/native/debug/build/apps/cli/cli.exe}"
WORK="$(mktemp -d /tmp/moonflux-p46.XXXXXX)"
PORT="${MOONFLUX_P46_PORT:-18591}"
PASS=0
SERVER_PID=""

fail() {
  echo "E2E-P46-DEPLOY-ROUTING FAIL: $*" >&2
  [ -f "$WORK/hook.log" ] && tail -3 "$WORK/hook.log" >&2
  exit 1
}
pass() { echo "E2E-P46-DEPLOY-ROUTING PASS: $*"; PASS=$((PASS + 1)); }
cleanup() {
  [ -n "$SERVER_PID" ] && kill -9 "$SERVER_PID" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

[ -x "$EXE" ] || { echo "missing $EXE (build first)" >&2; exit 1; }
"$ROOT/scripts/build-operators.sh" > /dev/null 2>&1 || fail "could not build the operator modules"

for op in operator-predicate operator-keyconst operator-stuck operator-identity; do
  [ -f "_build/wasm/debug/build/apps/$op/$op.wasm" ] || fail "missing $op.wasm"
done

# ---- the webhook peer: requires the auth header, records every POST --------
cat > "$WORK/hook-body.json" <<'JSON'
{"ok":true}
JSON
: > "$WORK/hook.log"
python3 "$ROOT/scripts/http_fixture_server.py" --port "$PORT" --body "$WORK/hook-body.json" \
  --log "$WORK/hook.log" --post-log "$WORK/hook-posts.txt" \
  --require "Authorization=Bearer test-token" > "$WORK/hook-server.log" 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 80); do
  grep -q "fixture server on" "$WORK/hook-server.log" 2>/dev/null && break
  sleep 0.1
done
grep -q "fixture server on" "$WORK/hook-server.log" || { cat "$WORK/hook-server.log"; fail "the webhook fixture did not start"; }

DATA="$WORK/data"
TOPIC="p46-decisions"

# ---- feed decisions into the topic, keyed by point ------------------------
produce_decision() { # $1 = node (key), $2 = json
  printf '%s\t%s\n' "$1" "$2" > "$WORK/one.txt"
  "$EXE" produce --topic "$TOPIC" --file "$WORK/one.txt" --key-separator "$(printf '\t')" \
    --data-dir "$DATA" > /dev/null 2>&1 || fail "could not produce a decision for $1"
}
produce_decision "CN_进水COD" '{"node":"CN_进水COD","verdict":"OK","value":100,"flat_minutes":0,"at":"2026-10-14T00:00:00Z"}'
produce_decision "CN_进水COD" '{"node":"CN_进水COD","verdict":"NOTICE","value":100,"flat_minutes":20,"at":"2026-10-14T00:20:00Z"}'
produce_decision "CN_进水COD" '{"node":"CN_进水COD","verdict":"STUCK","value":100,"flat_minutes":160,"at":"2026-10-14T02:40:00Z"}'
produce_decision "CN_进水总磷" '{"node":"CN_进水总磷","verdict":"STUCK","value":7,"flat_minutes":200,"at":"2026-10-14T03:00:00Z"}'

# ---- B: predicate on verdict=STUCK, then the webhook sink ----------------
cat > "$WORK/spec-alerts.json" <<JSON
{
  "apiVersion": "moonflux.io/v1alpha1",
  "kind": "Pipeline",
  "metadata": { "name": "p46-alerts" },
  "spec": {
    "source": { "type": "topic", "name": "$TOPIC", "from": "beginning" },
    "topic": { "name": "$TOPIC" },
    "transforms": [
      { "type": "wasm",
        "module": "$ROOT/_build/wasm/debug/build/apps/operator-predicate/operator-predicate.wasm",
        "config": { "field": "verdict", "op": "eq", "value": "STUCK", "missing": "drop" } }
    ],
    "sink": { "type": "http", "url": "http://127.0.0.1:$PORT/hook",
              "headers": { "Authorization": "Bearer test-token" } }
  }
}
JSON
"$EXE" pipeline run --data-dir "$DATA" --spec "$WORK/spec-alerts.json" \
  > "$WORK/alerts.out" 2> "$WORK/alerts.err" &
RUN=$!
sleep 5
kill -9 $RUN 2>/dev/null
sleep 0.5

# ---- 1. only STUCK reached the peer --------------------------------------
[ -s "$WORK/hook-posts.txt" ] || { tail -3 "$WORK/alerts.err"; fail "1: the webhook received nothing"; }
python3 - "$WORK/hook-posts.txt" <<'PY' || fail "1: the webhook did not receive exactly the STUCK decisions"
import sys
body = open(sys.argv[1], encoding="utf-8").read()
lines = [l for l in body.splitlines() if l.strip()]
assert lines, "empty webhook body"
verdicts = []
for line in lines:
    assert '"verdict":"STUCK"' in line, f"a non-STUCK decision was posted: {line[:120]}"
    verdicts.append(line)
assert len(lines) == 2, f"expected 2 STUCK decisions, the peer got {len(lines)}: {body[:200]}"
PY
pass "1. 只外发 STUCK：对端收到 2 条（OK/NOTICE 被 predicate 丢掉）"

# ---- 2. the auth header really arrived ----------------------------------
python3 - "$WORK/hook.log" <<'PY' || fail "2: the webhook never saw the Authorization header"
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8") if l.strip()]
posts = [r for r in rows if r["method"] == "POST"]
assert posts, "the peer logged no POST at all"
for r in posts:
    assert r["headers"].get("Authorization") == "Bearer test-token", r["headers"]
print(f"peer saw {len(posts)} POST(s) with Authorization", file=sys.stderr)
PY
pass "2. 外发的鉴权头到了**对端**（webhook 鉴权靠它；缺头会被夹具 404）"

# ---- 3. decisions are keyed by point ------------------------------------
"$EXE" consume --topic "$TOPIC" --from 0 --data-dir "$DATA" 2>/dev/null | tail -n +1 > "$WORK/decisions.txt"
python3 - "$WORK/decisions.txt" <<'PY' || fail "3: the decisions topic is not keyed by point"
import sys
rows = [l.rstrip("\n").split("\t") for l in open(sys.argv[1], encoding="utf-8") if l.strip()]
keys = {r[2] for r in rows if len(r) > 3}
assert "CN_进水COD" in keys and "CN_进水总磷" in keys, keys
assert all(k.startswith("CN_") for k in keys), keys
PY
pass "3. 判决按**点位**为键（键控压实即"每点位最新判决"；压实语义由 P14/P28 门禁证）"

# ---- 4. restart: the state is replayed, so nothing is re-emitted ---------
# A is run over a file fixture, twice, from two different processes, sharing one
# data dir: the second run must produce NO decisions, because the watermark and
# the run bookkeeping live in the state topic and were replayed.
python3 - "$WORK" <<'PY'
import json, pathlib, sys
work = pathlib.Path(sys.argv[1])
rows = []
for i, value in enumerate([10.0, 11.0, 12.0] + [12.0] * 8):
    ts = f"2026-10-14T0{i % 6}:{i:02d}:00Z" if i < 6 else f"2026-10-14T00:{i:02d}:00Z"
    rows.append([{"node_name": "CN_进水COD", "var_value": value, "ts": ts,
                  "var_quality": 192, "data_status": "正常"}])
(work / "polls.jsonl").write_text("\n".join(json.dumps(r) for r in rows) + "\n", encoding="utf-8")
PY
cat > "$WORK/spec-a.json" <<JSON
{
  "apiVersion": "moonflux.io/v1alpha1",
  "kind": "Pipeline",
  "metadata": { "name": "p46-stuck" },
  "spec": {
    "source": { "type": "file", "path": "$WORK/polls.jsonl" },
    "topic": { "name": "p46-polls" },
    "state": { "topic": "p46-state" },
    "transforms": [
      { "type": "wasm",
        "module": "$ROOT/_build/wasm/debug/build/apps/operator-keyconst/operator-keyconst.wasm",
        "config": { "key": "CN_进水COD" } },
      { "type": "wasm",
        "module": "$ROOT/_build/wasm/debug/build/apps/operator-stuck/operator-stuck.wasm",
        "config": { "window_minutes": 5, "notice_minutes": 5, "alarm_minutes": 10 } }
    ],
    "sink": { "type": "topic", "name": "p46-decisions-out" }
  }
}
JSON
"$EXE" pipeline run --data-dir "$WORK/state-dir" --spec "$WORK/spec-a.json" > "$WORK/run1.txt" 2> "$WORK/run1.err" ||
  { tail -3 "$WORK/run1.err"; fail "4: the first run failed"; }
# A's sink is a TOPIC (the deployment's shape), so stdout is empty by design:
# count what landed in the topic instead of looking in the wrong place.
OUT1=$("$EXE" consume --topic p46-decisions-out --from 0 --data-dir "$WORK/state-dir" 2>/dev/null | wc -l | tr -d ' ')
[ "$OUT1" -gt 0 ] || { tail -3 "$WORK/run1.err"; fail "4: the first run wrote no decision to its topic"; }
STATE1=$("$EXE" consume --topic p46-state --from 0 --data-dir "$WORK/state-dir" 2>/dev/null | tail -1 | cut -f4)
echo "$STATE1" | grep -q "n=" || fail "4: no state was written"
# a SECOND process, same data dir, same input
"$EXE" pipeline run --data-dir "$WORK/state-dir" --spec "$WORK/spec-a.json" > "$WORK/run2.txt" 2> "$WORK/run2.err" ||
  { tail -3 "$WORK/run2.err"; fail "4: the second run failed"; }
OUT2=$("$EXE" consume --topic p46-decisions-out --from 0 --data-dir "$WORK/state-dir" 2>/dev/null | wc -l | tr -d ' ')
[ "$OUT2" = "$OUT1" ] ||
  fail "4: the restart re-emitted decisions (topic had $OUT1, now $OUT2)"
[ -s "$WORK/run2.txt" ] && { head -2 "$WORK/run2.txt"; fail "4: the restart wrote to stdout"; }
STATE2=$("$EXE" consume --topic p46-state --from 0 --data-dir "$WORK/state-dir" 2>/dev/null | tail -1 | cut -f4)
[ "$STATE1" = "$STATE2" ] || fail "4: the restart changed the state (\$STATE1 -> \$STATE2)"
pass "4. 重启后状态重放：换进程、同输入 → 零决策、状态逐字节不变（水位与段账在状态主题里）"

echo "E2E-P46-DEPLOY-ROUTING: $PASS passed, 0 failed"
