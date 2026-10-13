#!/bin/bash
# E2E-P43-STUCK: 点位恒值（卡值）算子
#
# 这条门禁证明的是"有状态滑动窗口判恒值"这件事本身，以及它**回答的是哪个问题**：
#
#   1  值在动 -> OK（窗口里有变化，这就是"最近 N 分钟是否出现恒值"的答案）
#   2  恒定过提示线但没到告警线 -> NOTICE（提示，不打扰）
#   3  恒定越过告警线 -> STUCK
#   4  **可疑值立刻 STUCK**，不等时长（真实数据里出现过恒值 5000 持续 238 分钟）
#   5  **坏样本不参与判断**：var_quality=0 的行既不算"变了"也不算"没变"
#   6  **断流不切断段，但如实记下**：中间 5 分钟无数据 -> 发 NO_DATA、gaps+1，
#      而这一段继续累计（否则 4 小时的卡值会被一次抖动藏起来——这条是实测修出来的）
#   7  **状态跨调用累积**：同一数据目录跑第二段，计数与当前值继续前进
#      （实测修过的一个真 bug：只回写"首次出现的键"会让状态在第一批之后冻住）
#   8  **重复轮询不改变任何东西**：同一份夹具再跑一次，水位挡住旧行
#   9  键是**点位**：另一个点位并行时各有各的段与计数
#
# 夹具在 scripts/testdata/stuck-episodes*.jsonl：取值/时间与真实点位同形，
# 时间轴压到分钟级（判据只看记录自带的事件时间，压缩不改变语义），阈值在本门禁里
# 缩到可测规模（提示 5 分钟 / 告警 10 分钟），而线上默认是 10 / 150（见决策 88）。
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

EXE="${MOONFLUX_EXE:-$ROOT/_build/native/debug/build/apps/cli/cli.exe}"
WORK="$(mktemp -d /tmp/moonflux-p43.XXXXXX)"
PASS=0

fail() { echo "E2E-P43-STUCK FAIL: $*" >&2; exit 1; }
pass() { echo "E2E-P43-STUCK PASS: $*"; PASS=$((PASS + 1)); }
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

[ -x "$EXE" ] || { echo "missing $EXE (build first)" >&2; exit 1; }
"$ROOT/scripts/build-operators.sh" > /dev/null 2>&1 || fail "could not build the operator modules"
for op in operator-stuck operator-keyconst; do
  [ -f "_build/wasm/debug/build/apps/$op/$op.wasm" ] ||
    fail "missing _build/wasm/debug/build/apps/$op/$op.wasm"
done

spec_for() { # $1 = fixture path, $2 = spec path, $3 = topic prefix
  cat > "$2" <<JSON
{
  "apiVersion": "moonflux.io/v1alpha1",
  "kind": "Pipeline",
  "metadata": { "name": "stuck-$3" },
  "spec": {
    "source": { "type": "file", "path": "$1" },
    "topic": { "name": "p43-$3-polls" },
    "state": { "topic": "p43-$3-state" },
    "transforms": [
      { "type": "wasm",
        "module": "$ROOT/_build/wasm/debug/build/apps/operator-keyconst/operator-keyconst.wasm",
        "config": { "key": "CN_进水COD" } },
      { "type": "wasm",
        "module": "$ROOT/_build/wasm/debug/build/apps/operator-stuck/operator-stuck.wasm",
        "config": { "window_minutes": 5, "notice_minutes": 5, "alarm_minutes": 10,
                    "max_gap_ms": 180000, "suspicious_values": [5000],
                    "clear_minutes": 2, "heartbeat_minutes": 30 } }
    ],
    "sink": { "type": "stdout" }
  }
}
JSON
}

DATA="$WORK/data"
spec_for "$ROOT/scripts/testdata/stuck-episodes.jsonl" "$WORK/spec.json" first
"$EXE" pipeline run --data-dir "$DATA" --spec "$WORK/spec.json" > "$WORK/out1.txt" 2> "$WORK/err1.txt" ||
  { tail -5 "$WORK/err1.txt"; fail "the first run failed"; }

decisions() { python3 - "$1" <<'PY'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1], encoding='utf-8') if l.strip()]
for r in rows:
    print(f"{r['verdict']}\t{r['value']}\t{r['flat_minutes']}\t{r['gaps']}")
PY
}
decisions "$WORK/out1.txt" > "$WORK/d1.tsv"
[ -s "$WORK/d1.tsv" ] || { cat "$WORK/out1.txt"; tail -3 "$WORK/err1.txt"; fail "no decisions were emitted at all"; }

# ---- 1/2/3: the ladder, by the fixture's own values ---------------------
python3 - "$WORK/d1.tsv" <<'PY' || fail "1/2/3: the verdict ladder is wrong"
import sys
rows = [l.rstrip("\n").split("\t") for l in open(sys.argv[1]) if l.strip()]
by_value = {}
for verdict, value, flat, gaps in rows:
    by_value.setdefault(float(value), []).append((verdict, float(flat), int(gaps)))
# 100.0..105.0: 值在动 -> 只应出现 OK
moving = [r for v, rs in by_value.items() if 100.0 <= v <= 105.0 for r in rs]
assert moving and all(r[0] == "OK" for r in moving), moving
# 200.0: 恒定 6 分钟 -> 出现过 NOTICE，且从未 STUCK（告警线 10 分钟）
flat6 = by_value.get(200.0, [])
assert any(r[0] == "NOTICE" for r in flat6), flat6
assert not any(r[0] == "STUCK" for r in flat6), flat6
# 300.0: 恒定 12 分钟 -> 必须 STUCK，且 flat>=10
flat12 = by_value.get(300.0, [])
stuck = [r for r in flat12 if r[0] == "STUCK"]
assert stuck and stuck[-1][1] >= 10.0, flat12
print("ladder ok", file=sys.stderr)
PY
pass "1/2/3. 值在动=OK、过提示线=NOTICE、越告警线=STUCK（按夹具自己的取值断言）"

# ---- 4: a suspicious value is immediate --------------------------------
python3 - "$WORK/d1.tsv" <<'PY' || fail "4: a suspicious value was not caught immediately"
import sys
rows = [l.rstrip("\n").split("\t") for l in open(sys.argv[1]) if l.strip()]
sus = [r for r in rows if float(r[1]) == 5000.0]
assert sus, "no decision for the suspicious value"
assert any(r[0] == "STUCK" for r in sus), sus
first = min(float(r[2]) for r in sus if r[0] == "STUCK")
assert first <= 1.0, f"the suspicious value was not caught immediately (flat={first})"
PY
pass "4. 可疑值 5000 在 1 分钟内就 STUCK（不等时长）"

# ---- 5: bad-quality rows are not evidence ------------------------------
if python3 - "$WORK/d1.tsv" <<'PY'
import sys
rows = [l.rstrip("\n").split("\t") for l in open(sys.argv[1]) if l.strip()]
raise SystemExit(1 if any(float(r[1]) in (400.0, 401.0) for r in rows) else 0)
PY
then :; else fail "5: a var_quality=0 row produced a decision"; fi
pass "5. var_quality=0 的行一个决策都不产生（坏样本不是证据）"

# ---- 6: a gap is reported and does NOT break the run -------------------
python3 - "$WORK/d1.tsv" <<'PY' || fail "6: the gap was mishandled"
import sys
rows = [l.rstrip("\n").split("\t") for l in open(sys.argv[1]) if l.strip()]
gap_rows = [r for r in rows if float(r[1]) == 500.0]
assert any(r[0] == "NO_DATA" for r in gap_rows), gap_rows
assert any(int(r[3]) == 1 for r in gap_rows), gap_rows
after = [r for r in gap_rows if r[0] != "NO_DATA"]
assert after, f"the run did not continue after the gap: {gap_rows}"
# 段没被切断：断流之后的 flat 应该把断流前的时间算进去（>= 3 分钟）
assert max(float(r[2]) for r in after) >= 3.0, gap_rows
PY
pass "6. 断流发 NO_DATA、gaps 记 1、而段继续累计（不被切碎）"

# ---- 7: state accumulates across calls ---------------------------------
STATE1="$("$EXE" consume --topic p43-first-state --from 0 --data-dir "$DATA" 2>/dev/null | tail -1 | cut -f4)"
echo "$STATE1" | grep -q "n=[1-9]" || fail "7: no completed run was recorded ($STATE1)"
SPEC_N1=$(echo "$STATE1" | sed 's/.*n=\([0-9]*\).*/\1/')
OVER_A1=$(echo "$STATE1" | sed 's/.*over_a=\([0-9]*\).*/\1/')
[ "$OVER_A1" -ge 1 ] || fail "7: the 12-minute flat run was not counted as over the alarm line ($STATE1)"
spec_for "$ROOT/scripts/testdata/stuck-episodes2.jsonl" "$WORK/spec2.json" first
"$EXE" pipeline run --data-dir "$DATA" --spec "$WORK/spec2.json" > "$WORK/out2.txt" 2> "$WORK/err2.txt" ||
  { tail -5 "$WORK/err2.txt"; fail "7: the second run failed"; }
STATE2="$("$EXE" consume --topic p43-first-state --from 0 --data-dir "$DATA" 2>/dev/null | tail -1 | cut -f4)"
SPEC_N2=$(echo "$STATE2" | sed 's/.*n=\([0-9]*\).*/\1/')
[ "${SPEC_N2:-0}" -gt "${SPEC_N1:-0}" ] ||
  fail "7: the counters did not advance across calls (n $SPEC_N1 -> ${SPEC_N2:-?}; $STATE2)"
echo "$STATE2" | grep -q "v=603" || fail "7: the current value did not advance ($STATE2)"
pass "7. 状态跨调用累积（n $SPEC_N1 → ${SPEC_N2}，当前值跟进），空回写那个 bug 有护栏"

# ---- 8: re-polling the same rows changes nothing -----------------------
"$EXE" pipeline run --data-dir "$DATA" --spec "$WORK/spec2.json" > "$WORK/out3.txt" 2> /dev/null ||
  fail "8: the repeat run failed"
[ -s "$WORK/out3.txt" ] && fail "8: re-polling the same rows produced decisions"
STATE3="$("$EXE" consume --topic p43-first-state --from 0 --data-dir "$DATA" 2>/dev/null | tail -1 | cut -f4)"
[ "$STATE3" = "$STATE2" ] || fail "8: re-polling changed the state"
pass "8. 同一份数据再轮询一次：零决策、状态不变（水位挡住了旧行）"

# ---- 9: the key is the point, not a global -----------------------------
spec_for "$ROOT/scripts/testdata/stuck-episodes-other.jsonl" "$WORK/spec3.json" other
"$EXE" pipeline run --data-dir "$WORK/data-other" --spec "$WORK/spec3.json" > "$WORK/out4.txt" 2> /dev/null ||
  fail "9: the other-point run failed"
python3 - "$WORK/out4.txt" <<'PY' || fail "9: the other point was not judged on its own"
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1], encoding='utf-8') if l.strip()]
assert rows, "no decisions for the other point"
assert all(r["node"] == "CN_进水总磷" for r in rows), [r["node"] for r in rows]
assert all(r["runs"] <= 1 for r in rows), [r["runs"] for r in rows]
PY
pass "9. 另一个点位（CN_进水总磷）各有各的段与计数（键是点位）"

echo "E2E-P43-STUCK: $PASS passed, 0 failed"
