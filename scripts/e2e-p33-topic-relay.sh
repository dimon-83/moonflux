#!/bin/bash
# E2E-P33-TOPIC-RELAY: pipeline 以主题为源 + 主题汇（P31/T116，决策 72）
#
# 这是缺口 7（"pipeline 不能以主题为源"）的门禁。它断言的是**能力**，不是速度：
#
#   1 主题汇：A 的变换结果落进主题，`consume` 能逐字节读回
#   2 主题源 from=beginning：B 从 0 读到 A 写的全部
#   3 主题源 from=end：先起的跟随者不看历史（起点是**声明**，不是"上次读到哪"）
#   4 主题源 from=<offset>：从中间开始，偏移是绝对的
#   5 跨进程跟随：A 在 B 运行期间追加的记录，B 必须读到
#     （这条是**真问题**的门禁：日志句柄的 end 是本进程视图，跟随者必须重开）
#   6 接力三段：file → topic → topic → topic → stdout，逐段可查
#   7 环校验：sink == 数据主题 / sink == 状态主题 / source == 状态主题 /
#     source 名字与 spec.topic 不一致——四种都在 **apply 期**按名拒绝且零输出
#   8 流式：主题源从不报 Exhausted（追平后是 Quiet），进程不自己退出
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

EXE="${MOONFLUX_EXE:-$ROOT/_build/native/debug/build/apps/cli/cli.exe}"
WASM="_build/wasm/debug/build/apps"
WORK="$(mktemp -d)"
PASS=0
FAIL=0

# This gate starts `pipeline run` children with `&` and kills them explicitly on
# the happy path. A failure BETWEEN the two leaves them running — and before the
# suite detached itself (decision 101) such a survivor held the caller's stdout
# open, which is how "a gate hung" and "the caller died" turned out to be one
# event. The sweep is scoped to THIS gate's temp dir on purpose: an unscoped
# pkill can kill something it never started. Found by scripts/audit-gate-hygiene.py.
cleanup() {
  # `pkill -f ""` matches EVERY process: refuse to run with nothing in the
  # variable. This cleanup can run on a CI runner shared with the runner
  # agent itself, so an empty pattern is a machine-wide kill.
  [ -n "$WORK" ] || return 0
  pkill -f "$WORK" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

fail() { echo "E2E-P33-TOPIC-RELAY FAIL: $*" >&2; FAIL=$((FAIL + 1)); }
pass() { echo "E2E-P33-TOPIC-RELAY PASS: $*"; PASS=$((PASS + 1)); }
wait_for_lines() { # file count tenths
  local f="$1" want="$2" tenths="$3" i=0
  while [ "$i" -lt "$tenths" ]; do
    [ "$(wc -l < "$f" | tr -d ' ')" -ge "$want" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

check() { # name file expected
  if diff -q "$2" "$3" > /dev/null; then
    pass "$1"
  else
    echo "--- actual ---" >&2; cat "$2" >&2; echo "--- expected ---" >&2; cat "$3" >&2
    fail "$1 (byte mismatch)"
  fi
}

[ -x "$EXE" ] || { echo "missing $EXE (build first)" >&2; exit 1; }
"$ROOT/scripts/build-operators.sh" > /dev/null 2>&1

D="$WORK/replay"
mkdir -p "$D"

# ---------------------------------------------------------------- fixtures
cat > "$WORK/in.txt" <<'EOF'
alpha beta
gamma
EOF

spec_a() { # file path -> topic -> topic sink
  cat > "$1" <<JSON
{"apiVersion":"moonflux.io/v1alpha1","kind":"Pipeline","metadata":{"name":"p33-a"},
 "spec":{"source":{"type":"file","path":"$WORK/in.txt"},
 "topic":{"name":"p33-in"},
 "transforms":[{"type":"wasm","module":"$WASM/operator-wordkeys/operator-wordkeys.wasm","config":{}}],
 "sink":{"type":"topic","name":"p33-words"}}}
JSON
}

spec_b() { # from -> stdout (a follower of p33-words)
  cat > "$1" <<JSON
{"apiVersion":"moonflux.io/v1alpha1","kind":"Pipeline","metadata":{"name":"p33-b"},
 "spec":{"source":{"type":"topic","name":"p33-words","from":$2},
 "topic":{"name":"p33-words"},
 "transforms":[{"type":"wasm","module":"$WASM/operator-upper/operator-upper.wasm","config":{}}],
 "sink":{"type":"stdout"}}}
JSON
}

# ---- 1. the topic sink ----------------------------------------------------
spec_a "$WORK/a.json"
"$EXE" pipeline run --data-dir "$D" --spec "$WORK/a.json" > /dev/null 2> "$WORK/1.err" ||
  { cat "$WORK/1.err"; fail "1: the topic-sink pipeline failed"; }
"$EXE" consume --topic p33-words --from 0 --data-dir "$D" 2>/dev/null | cut -f4 > "$WORK/1.out"
printf 'alpha\nbeta\ngamma\n' > "$WORK/1.expected"
check "1 topic sink" "$WORK/1.out" "$WORK/1.expected"

# ---- 2. topic source from beginning --------------------------------------
spec_b "$WORK/b.json" '"beginning"'
"$EXE" pipeline run --data-dir "$D" --spec "$WORK/b.json" > "$WORK/2.out" 2> "$WORK/2.err" &
BPID=$!
wait_for_lines "$WORK/2.out" 3 60 || true
kill $BPID 2>/dev/null; wait $BPID 2>/dev/null
printf 'ALPHA\nBETA\nGAMMA\n' > "$WORK/2.expected"
check "2 topic source from beginning" "$WORK/2.out" "$WORK/2.expected"

# ---- 3. from=end skips what is already there ------------------------------
spec_b "$WORK/b_end.json" '"end"'
"$EXE" pipeline run --data-dir "$D" --spec "$WORK/b_end.json" > "$WORK/3.out" 2>/dev/null &
BPID=$!
sleep 0.6
kill $BPID 2>/dev/null; wait $BPID 2>/dev/null
[ ! -s "$WORK/3.out" ] || { cat "$WORK/3.out"; fail "3: from=end delivered history"; }
pass "3 from=end delivers nothing that was already in the log"

# ---- 4. from=<offset> starts in the middle --------------------------------
spec_b "$WORK/b_off.json" '2'
"$EXE" pipeline run --data-dir "$D" --spec "$WORK/b_off.json" > "$WORK/4.out" 2>/dev/null &
BPID=$!
wait_for_lines "$WORK/4.out" 1 60 || true
kill $BPID 2>/dev/null; wait $BPID 2>/dev/null
printf 'GAMMA\n' > "$WORK/4.expected"
check "4 topic source from offset 2" "$WORK/4.out" "$WORK/4.expected"

# ---- 5. cross-process following ------------------------------------------
# The one that matters: B is reading while A appends. A cached handle cannot
# see another process's bytes (logcache.mbt's "one process, one writer"), so
# the follower has to re-open. Without this, B reads the history and then
# waits forever while the relay quietly does nothing.
spec_b "$WORK/b_live.json" '"beginning"'
"$EXE" pipeline run --data-dir "$D" --spec "$WORK/b_live.json" > "$WORK/5.out" 2>/dev/null &
BPID=$!
sleep 0.5
cat > "$WORK/in2.txt" <<'EOF'
delta epsilon
EOF
spec_a2="$WORK/a2.json"
sed -e "s|$WORK/in.txt|$WORK/in2.txt|" -e 's|"name":"p33-in"|"name":"p33-in-2"|' "$WORK/a.json" > "$spec_a2"
"$EXE" pipeline run --data-dir "$D" --spec "$spec_a2" > /dev/null 2>&1
sleep 1.0
kill $BPID 2>/dev/null; wait $BPID 2>/dev/null
printf 'ALPHA\nBETA\nGAMMA\nDELTA\nEPSILON\n' > "$WORK/5.expected"
check "5 cross-process following" "$WORK/5.out" "$WORK/5.expected"

# ---- 6. a three-leg relay -------------------------------------------------
# file -> topic -> (upper) -> topic -> (reverse-free prefix) -> stdout
spec_c() {
  cat > "$1" <<JSON
{"apiVersion":"moonflux.io/v1alpha1","kind":"Pipeline","metadata":{"name":"p33-c"},
 "spec":{"source":{"type":"topic","name":"p33-upper"},"topic":{"name":"p33-upper"},
 "transforms":[{"type":"wasm","module":"$WASM/operator-filter/operator-filter.wasm","config":{"min_len":1}}],
 "sink":{"type":"topic","name":"p33-final"}}}
JSON
}
spec_b2() {
  cat > "$1" <<JSON
{"apiVersion":"moonflux.io/v1alpha1","kind":"Pipeline","metadata":{"name":"p33-b2"},
 "spec":{"source":{"type":"topic","name":"p33-words"},"topic":{"name":"p33-words"},
 "transforms":[{"type":"wasm","module":"$WASM/operator-upper/operator-upper.wasm","config":{}}],
 "sink":{"type":"topic","name":"p33-upper"}}}
JSON
}
spec_c "$WORK/c.json"
spec_b2 "$WORK/b2.json"
"$EXE" pipeline run --data-dir "$D" --spec "$WORK/b2.json" > /dev/null 2>&1 &
C1=$!
sleep 0.5
"$EXE" pipeline run --data-dir "$D" --spec "$WORK/c.json" > /dev/null 2>&1 &
C2=$!
sleep 0.5
cat > "$WORK/in3.txt" <<'EOF'
zeta
EOF
sed -e "s|$WORK/in.txt|$WORK/in3.txt|" -e 's|"name":"p33-in"|"name":"p33-in-3"|' "$WORK/a.json" > "$WORK/a3.json"
"$EXE" pipeline run --data-dir "$D" --spec "$WORK/a3.json" > /dev/null 2>&1
sleep 1.0
kill $C1 $C2 2>/dev/null; wait $C1 $C2 2>/dev/null
"$EXE" consume --topic p33-final --from 0 --data-dir "$D" 2>/dev/null | cut -f4 > "$WORK/6.out"
printf 'ALPHA\nBETA\nGAMMA\nDELTA\nEPSILON\nZETA\n' > "$WORK/6.expected"
check "6 three-leg relay" "$WORK/6.out" "$WORK/6.expected"

# ---- 7. the ring refusals -------------------------------------------------
ring() { # name file
  if "$EXE" pipeline plan --file "$2" > "$WORK/7.out" 2> "$WORK/7.err"; then
    fail "7 $1: the wiring was accepted"
  else
    if [ -s "$WORK/7.out" ]; then
      fail "7 $1: a refused spec still produced a plan"
    elif grep -q "$3" "$WORK/7.err"; then
      pass "7 $1 is refused by name"
    else
      cat "$WORK/7.err" >&2
      fail "7 $1: the refusal does not name the reason"
    fi
  fi
}
cat > "$WORK/ring-sink.json" <<JSON
{"apiVersion":"moonflux.io/v1alpha1","kind":"Pipeline","metadata":{"name":"ring1"},
 "spec":{"source":{"type":"topic","name":"t1"},"topic":{"name":"t1"},
 "transforms":[],"sink":{"type":"topic","name":"t1"}}}
JSON
ring "sink == data topic" "$WORK/ring-sink.json" "a ring"
cat > "$WORK/ring-state.json" <<JSON
{"apiVersion":"moonflux.io/v1alpha1","kind":"Pipeline","metadata":{"name":"ring2"},
 "spec":{"source":{"type":"topic","name":"t1"},"topic":{"name":"t1"},
 "state":{"topic":"t1"},"transforms":[],"sink":{"type":"stdout"}}}
JSON
# state == source is state == data (a topic source must name its own topic),
# so the rule that fires is the older one — assert THAT message, not a wished-for one
ring "state == source topic" "$WORK/ring-state.json" "state topic must differ from the data topic"
cat > "$WORK/ring-sinkstate.json" <<JSON
{"apiVersion":"moonflux.io/v1alpha1","kind":"Pipeline","metadata":{"name":"ring3"},
 "spec":{"source":{"type":"file","path":"$WORK/in.txt"},"topic":{"name":"t2"},
 "state":{"topic":"t3"},"transforms":[],"sink":{"type":"topic","name":"t3"}}}
JSON
ring "sink == state topic" "$WORK/ring-sinkstate.json" "memory is not a data topic"
cat > "$WORK/ring-name.json" <<JSON
{"apiVersion":"moonflux.io/v1alpha1","kind":"Pipeline","metadata":{"name":"ring4"},
 "spec":{"source":{"type":"topic","name":"elsewhere"},"topic":{"name":"t4"},
 "transforms":[],"sink":{"type":"stdout"}}}
JSON
ring "source names another topic" "$WORK/ring-name.json" "must name the pipeline's own topic"

# ---- 8. a topic source never says Exhausted -------------------------------
# It streams: catch up, wait, look again. A run that exited on its own here
# would be a relay that stops after the first replay.
"$EXE" pipeline run --data-dir "$D" --spec "$WORK/b_end.json" > /dev/null 2> "$WORK/8.err" &
BPID=$!
sleep 1.2
if kill -0 $BPID 2>/dev/null; then
  pass "8 a caught-up topic source keeps running (Quiet, never Exhausted)"
  kill $BPID 2>/dev/null
else
  fail "8 the topic source exited on its own"
fi
wait $BPID 2>/dev/null

echo "E2E-P33-TOPIC-RELAY: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ] || exit 1
