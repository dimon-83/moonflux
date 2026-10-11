#!/bin/bash
# E2E-P35-METRICS: 可观测面（P35，决策 76）
#
# 对着 production-readiness §3 的第 3 条："无 metrics、无健康端点——监控只能刮日志、
# 用 CLI 轮询"。这一条门禁断言的是**可证伪的事实**，不是"有个端点"：
#
#   1  启动时明示：给了 --metrics-listen 就打印它，没给就打印"disabled"
#   2  /metrics 是 200 + text/plain，且包含文档里写的名字
#   3  /healthz 是 200 + JSON，三项检查都是真的读（metadata/applied/metrics）
#   4  计数器随**已知动作**前进：建主题、取数各一次，对应 cmd 标签各 +1
#   5  gauge 是**实时读**：建主题前后 moonflux_topics 从 0 变 1
#   6  计数器单调：两次刮取之间不减少
#   7  错误计数器只数错误：正常握手（WELCOME=2）不得被计成 ERR_UNKNOWN_COMMAND(=2)
#      —— 这是我自己第一版真犯过的错，/metrics 当场把它照出来了
#   8  未知道路 404；在 metrics 端口上说 MFS（非 HTTP）得到 4xx 而不是挂住
#   9  HA 的 standby 必须**不健康**（503 + lease failed）：负载均衡器据此不导流
#  10 非回环 + 已开认证 ⇒ 启动即大声警告（P12 的规矩延伸到新表面）
#
# 决策 33 的落实：门禁只断言 `moonflux_uptime_ms` **存在**，绝不断言它的值。
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

EXE="${MOONFLUX_EXE:-$ROOT/_build/native/debug/build/apps/cli/cli.exe}"
WORK="$(mktemp -d)"
PASS=0
FAIL=0
PIDS=""

# a failing leg STOPS the gate: a leg that fails and then prints PASS is the
# worst kind of gate bug (measured here — the non-HTTP leg failed and the very
# next line reported it green)
fail() { echo "E2E-P35-METRICS FAIL: $*" >&2; exit 1; }
pass() { echo "E2E-P35-METRICS PASS: $*"; PASS=$((PASS + 1)); }

cleanup() {
  if [ -f "$WORK/pids" ]; then
    for pid in $(cat "$WORK/pids"); do
      kill "$pid" 2>/dev/null
    done
  fi
  wait 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

start_server() { # data-dir port metrics-port [extra...]  -> pid
  local dir="$1" port="$2" metrics="$3"
  shift 3
  "$EXE" serve --data-dir "$dir" --listen "127.0.0.1:$port" \
    --metrics-listen "127.0.0.1:$metrics" "$@" > "$WORK/serve-$port.log" 2>&1 &
  local pid=$!
  echo "$pid" >> "$WORK/pids"
  echo "$pid"
}

wait_listen() { # port tenths
  local port="$1" tenths="${2:-60}" i=0
  while [ "$i" -lt "$tenths" ]; do
    lsof -i ":$port" -sTCP:LISTEN > /dev/null 2>&1 && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# scrape <url> -> body on stdout, status on stderr-free exit 0/1
scrape() {
  python3 - "$1" <<'PY'
import sys, urllib.request, urllib.error
try:
    with urllib.request.urlopen(sys.argv[1], timeout=5) as r:
        sys.stdout.write(r.read().decode())
except urllib.error.HTTPError as e:
    sys.stdout.write(e.read().decode())
    sys.exit(0 if e.code in (400, 404, 503) else 1)
except Exception as e:
    sys.stderr.write(str(e))
    sys.exit(1)
PY
}

http_status() {
  python3 - "$1" <<'PY'
import sys, urllib.request, urllib.error
try:
    with urllib.request.urlopen(sys.argv[1], timeout=5) as r:
        print(r.status)
except urllib.error.HTTPError as e:
    print(e.code)
except Exception:
    print(0)
PY
}

[ -x "$EXE" ] || { echo "missing $EXE (build first)" >&2; exit 1; }

D="$WORK/broker"
P=19701
M=19702
SRV=$(start_server "$D" "$P" "$M")
wait_listen "$M" 100 || { cat "$WORK/serve-$P.log"; fail "1: the metrics listener never came up"; }

# ---- 1. announced ---------------------------------------------------------
grep -q "metrics on http://127.0.0.1:$M/metrics" "$WORK/serve-$P.log" ||
  { cat "$WORK/serve-$P.log"; fail "1: startup does not announce the metrics surface"; }
pass "1. the metrics surface is announced at startup, address included"

# ---- 2. /metrics ----------------------------------------------------------
BODY=$(scrape "http://127.0.0.1:$M/metrics")
STATUS=$(http_status "http://127.0.0.1:$M/metrics")
[ "$STATUS" = "200" ] || fail "2: /metrics returned $STATUS"
for name in moonflux_connections_total moonflux_commands_total moonflux_uptime_ms; do
  echo "$BODY" | grep -q "^$name" ||
    { echo "$BODY" | head -12; fail "2: /metrics lacks $name"; }
done
pass "2. /metrics answers 200 with the documented names (uptime reported, never gated)"

# ---- 3. /healthz ----------------------------------------------------------
HEALTH=$(scrape "http://127.0.0.1:$M/healthz")
HSTATUS=$(http_status "http://127.0.0.1:$M/healthz")
[ "$HSTATUS" = "200" ] || fail "3: /healthz returned $HSTATUS"
for check in metadata applied_pipeline metrics; do
  echo "$HEALTH" | grep -q "\"$check\":\"ok\"" ||
    { echo "$HEALTH"; fail "3: /healthz does not report $check ok"; }
done
pass "3. /healthz reports ok, and each check is a real read"

# ---- 4/5. counters and gauges move with known actions --------------------
TOPICS_BEFORE=$(echo "$BODY" | awk '/^moonflux_topics /{print $2}')
"$EXE" topic create --remote "127.0.0.1:$P" --name orders --partitions 2 --replication-factor 1 \
  > /dev/null 2>&1 || fail "4: topic create failed"
"$EXE" topic list --remote "127.0.0.1:$P" > /dev/null 2>&1
sleep 0.3
AFTER=$(scrape "http://127.0.0.1:$M/metrics")
echo "$AFTER" | grep -qE '^moonflux_commands_total\{cmd="15"\} [1-9]' ||
  { echo "$AFTER"; fail "4: TOPIC_CREATE was not counted"; }
echo "$AFTER" | grep -qE '^moonflux_commands_total\{cmd="16"\} [1-9]' ||
  { echo "$AFTER"; fail "4: TOPIC_LIST was not counted"; }
echo "$AFTER" | grep -qE '^moonflux_connections_total [1-9]' ||
  { echo "$AFTER"; fail "4: no connection was counted"; }
pass "4. the counters moved with the actions the gate performed (cmds 15/16, connections)"

TOPICS_AFTER=$(echo "$AFTER" | awk '/^moonflux_topics /{print $2}')
[ "$TOPICS_AFTER" -gt "$TOPICS_BEFORE" ] ||
  { echo "$AFTER"; fail "5: the topics gauge did not follow the declaration ($TOPICS_BEFORE -> $TOPICS_AFTER)"; }
pass "5. the gauge is a live read: topics went $TOPICS_BEFORE -> $TOPICS_AFTER after one declaration"

# ---- 6. monotonic --------------------------------------------------------
python3 - "$BODY" "$AFTER" <<'PY' || fail "6: a counter went backwards between two scrapes"
import sys
def totals(text):
    out = {}
    for line in text.splitlines():
        parts = line.split(" ")
        if len(parts) == 2 and parts[0].startswith("moonflux_") and parts[0].endswith("_total"):
            out[parts[0]] = int(parts[1])
    return out
before, after = totals(sys.argv[1]), totals(sys.argv[2])
bad = [k for k, v in before.items() if after.get(k, 0) < v]
if bad:
    print("went backwards:", bad, file=sys.stderr)
    sys.exit(1)
PY
pass "6. every counter is monotonic across scrapes"

# ---- 7. an error is an error, and success is not -------------------------
# the series exists (pre-registered at zero) — assert the VALUE is zero, which
# is the stronger statement: absent could mean "not counted yet"
HELLO_ERR=$(echo "$AFTER" | awk '/code="2"/{print $2}')
[ "$HELLO_ERR" = "0" ] ||
  { echo "$AFTER"; fail "7: a completed handshake was counted as unknown-command ($HELLO_ERR)"; }
"$EXE" topic delete --remote "127.0.0.1:$P" --name never-existed > /dev/null 2>&1
sleep 0.3
ERRS=$(scrape "http://127.0.0.1:$M/metrics")
echo "$ERRS" | grep -qE '^moonflux_errors_total\{code="[0-9]+"\} [1-9]' ||
  { echo "$ERRS"; fail "7: a refused command was not counted as an error"; }
pass "7. a refused command is counted, and a completed handshake is not"

# ---- 8. unknown paths and non-HTTP ---------------------------------------
[ "$(http_status "http://127.0.0.1:$M/nope")" = "404" ] ||
  fail "8: an unknown path did not 404"
python3 - "$M" <<'PY' || fail "8: a non-HTTP request on the metrics port did not get a 4xx"
import socket, sys
port = int(sys.argv[1])
s = socket.create_connection(("127.0.0.1", port), timeout=3)
s.sendall(b"MFS\x02garbage\x00\x00")
s.settimeout(3)
try:
    data = s.recv(200)
except socket.timeout:
    print("timed out waiting for a reply", file=sys.stderr)
    sys.exit(1)
s.close()
sys.exit(0 if data.startswith(b"HTTP/1.0 4") else 1)
PY
pass "8. an unknown path 404s, and MFS bytes on the metrics port get a 4xx (never a hang)"

kill "$SRV" 2>/dev/null

# ---- 9. a standby is unhealthy -------------------------------------------
# A control plane that answers every command with "I am standby" must not be
# sent traffic by a load balancer; 503 with lease:failed is how it says so.
DH="$WORK/ha"
"$EXE" sc --data-dir "$DH" --listen 127.0.0.1:19713 --metrics-listen 127.0.0.1:19714 --ha \
  > "$WORK/sc-19713.log" 2>&1 &
SC1=$!
echo "$SC1" >> "$WORK/pids"
"$EXE" sc --data-dir "$DH" --listen 127.0.0.1:19715 --metrics-listen 127.0.0.1:19716 --ha \
  > "$WORK/sc-19715.log" 2>&1 &
SC2=$!
echo "$SC2" >> "$WORK/pids"
wait_listen 19714 100 || { cat "$WORK/sc-19713.log"; fail "9: the active control plane has no metrics listener"; }
wait_listen 19716 100 || { cat "$WORK/sc-19715.log"; fail "9: the standby has no metrics listener"; }
# Which of the two wins the lease is a race (whoever writes it first), so the
# leg asserts the INVARIANT: exactly one is healthy, the other says its lease
# failed and names it, and the healthy one is the address the lease names.
H1=$(http_status "http://127.0.0.1:19714/healthz")
H2=$(http_status "http://127.0.0.1:19716/healthz")
if [ "$H1" = "200" ] && [ "$H2" = "503" ]; then
  WINNER="127.0.0.1:19713"
  LOSER_BODY=$(scrape "http://127.0.0.1:19716/healthz")
elif [ "$H2" = "200" ] && [ "$H1" = "503" ]; then
  WINNER="127.0.0.1:19715"
  LOSER_BODY=$(scrape "http://127.0.0.1:19714/healthz")
else
  cat "$WORK/sc-19713.log" | tail -4
  cat "$WORK/sc-19715.log" | tail -4
  fail "9: health said $H1/$H2; exactly one control plane must be healthy"
fi
echo "$LOSER_BODY" | grep -q '"lease":"failed"' ||
  { echo "$LOSER_BODY"; fail "9: the unhealthy one does not name the lease"; }
HOLDER=$(python3 -c "import json;print(json.load(open('$DH/sc-lease.json'))['holder'])")
[ "$HOLDER" = "$WINNER" ] ||
  fail "9: the healthy control plane ($WINNER) is not the one the lease names ($HOLDER)"
pass "9. exactly one control plane is healthy (${WINNER}), the lease names it, and the other reports lease:failed"

# ---- 10. non-loopback while authenticated warns ---------------------------
DA="$WORK/auth"
mkdir -p "$DA"
cat > "$DA/auth.json" <<'JSON'
{"credentials":[{"token":"a-long-enough-token","name":"root","role":"root"}]}
JSON
"$EXE" serve --data-dir "$DA" --listen 127.0.0.1:19721 --metrics-listen 0.0.0.0:19722 \
  > "$WORK/warn.log" 2>&1 &
W=$!
echo "$W" >> "$WORK/pids"
for _ in $(seq 1 60); do
  grep -q "reachable off-host" "$WORK/warn.log" && break
  sleep 0.1
done
grep -q "reachable off-host" "$WORK/warn.log" ||
  { cat "$WORK/warn.log"; fail "10: metrics on 0.0.0.0 with authentication on did not warn"; }
pass "10. an off-host metrics surface next to authentication warns at startup"

echo "E2E-P35-METRICS: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ] || exit 1
