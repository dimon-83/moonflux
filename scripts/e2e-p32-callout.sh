#!/bin/bash
# E2E-P32: host-side HTTP callouts and the determinism choice (P30/T115).
#
# The design claim is narrow and testable: a pipeline that talks to the world
# must SAY SO (`mode` has no default), and once it has spoken, the same
# pipeline can be gated byte-exactly (replay) or run for real (live/record).
# Every leg below is one of those words turned into an assertion:
#
#   1  no mode            a callout without `mode` is refused at apply
#   2  live               the request really goes out, and the PEER says what
#                         it saw (scripts/http_mock.py logs every request)
#   3  record             a cassette is produced by a real run
#   4  replay             with the peer STOPPED, the answer is byte-identical
#   5  a cassette miss    is a named refusal with no output, never an empty 200
#   6  headers            are sent (peer sees them) and NEVER written to the
#                         cassette (the credential cannot leak by record)
#   7  the deadline       a stalling peer fails by name instead of hanging
#   8  the plan           shows the callout as host IO, i.e. the spec renders
#   9  no callout         an ordinary pipeline still runs (v1 regression)
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
EXE="${MOONFLUX_EXE:-$ROOT/_build/native/debug/build/apps/cli/cli.exe}"
WORK="$(mktemp -d /tmp/moonflux-p32-callout.XXXXXX)"
PORT="${MOONFLUX_P32_PORT:-18091}"
PIDS=()

cleanup() {
  for pid in "${PIDS[@]:-}"; do kill "$pid" 2>/dev/null || true; done
  for pid in $(lsof -ti ":$PORT" -sTCP:LISTEN 2>/dev/null); do kill "$pid" 2>/dev/null || true; done
  rm -rf "$WORK"
}
trap cleanup EXIT

fail() { echo "E2E-P32-CALLOUT FAIL: $*" >&2; exit 1; }
pass() { echo "E2E-P32-CALLOUT PASS: $*"; }
check() { # $1 label, $2 file, $3 expected text
  local got
  got="$(cat "$2")"
  [ "$got" = "$3" ] || fail "$1: got [$got], expected [$3]"
}

wait_listen() {
  for _ in $(seq 1 60); do
    lsof -i ":$1" -sTCP:LISTEN > /dev/null 2>&1 && return 0
    sleep 0.1
  done
  return 1
}

[ -x "$EXE" ] || fail "cli binary not found at $EXE (run: moon build --target native)"
[ -f "$ROOT/scripts/http_mock.py" ] || fail "scripts/http_mock.py is missing"

CARS="$ROOT/examples/sdf/22-http-callout/cars.jsonl"
[ -f "$CARS" ] || fail "the callout example's fixture is missing"

# ---- fixtures ----------------------------------------------------------
# The example's own specs use a shipped port; this gate runs its own peer on
# its own port, so the specs here are generated with that port.
write_spec() { # $1 name, $2 mode-or-empty, $3 extra json (may be empty)
  local mode_line=""
  if [ -n "$2" ]; then mode_line="\"mode\": \"$2\","; fi
  cat > "$WORK/$1.json" <<EOF
{
  "apiVersion": "moonflux.io/v1alpha1",
  "kind": "Pipeline",
  "metadata": { "name": "p32-$1" },
  "spec": {
    "source": { "type": "file", "path": "$CARS" },
    "topic": { "name": "cars-$1" },
    "transforms": [
      {
        "type": "callout",
        "method": "GET",
        "url": "http://127.0.0.1:$PORT/api/maker/{maker}",
        $mode_line
        "cassette": "$WORK/$1.cassette.jsonl"
        $3
      }
    ],
    "sink": { "type": "stdout" }
  }
}
EOF
}

# ---- 1. the determinism choice has no default --------------------------
write_spec "nomode" "" ""
"$EXE" pipeline run --data-dir "$WORK/d-nomode" --spec "$WORK/nomode.json" \
  > "$WORK/nomode.out" 2> "$WORK/nomode.err"
[ -s "$WORK/nomode.out" ] && fail "a callout without a mode produced output"
grep -q "callouts require a mode" "$WORK/nomode.err" ||
  { cat "$WORK/nomode.err"; fail "case 1: the missing mode is not named"; }
pass "1. a callout with no mode is refused at apply: determinism is not defaulted"

# ---- 2. live really calls, and the peer is the witness -----------------
python3 scripts/http_mock.py --port "$PORT" --log "$WORK/requests.jsonl" > "$WORK/mock.log" 2>&1 &
PIDS+=("$!")
wait_listen "$PORT" || { cat "$WORK/mock.log"; fail "the mock peer did not start"; }

write_spec "live" "live" ""
"$EXE" pipeline run --data-dir "$WORK/d-live" --spec "$WORK/live.json" \
  > "$WORK/live.out" 2> "$WORK/live.err" || { cat "$WORK/live.err"; fail "case 2: live run failed"; }
check "2 live answer" "$WORK/live.out" '{"maker": "Fiat", "country": "Italy", "continent": "Europe"}
{"maker": "Toyota", "country": "Japan", "continent": "Asia"}
{"maker": "Ford", "country": "United States", "continent": "North America"}
{"maker": "Tesla", "country": "United States", "continent": "North America"}'
# the peer's view, not the client's intention
[ "$(wc -l < "$WORK/requests.jsonl" | tr -d ' ')" = "4" ] ||
  fail "case 2: the peer did not see exactly four requests"
grep -q '"path": "/api/maker/Ford"' "$WORK/requests.jsonl" ||
  { cat "$WORK/requests.jsonl"; fail "case 2: the URL template did not fill from the record"; }
pass "2. live mode called the peer, and the peer's log shows the four templated URLs"

# ---- 3. record produces a cassette -------------------------------------
write_spec "record" "record" ""
"$EXE" pipeline run --data-dir "$WORK/d-record" --spec "$WORK/record.json" \
  > "$WORK/record.out" 2> "$WORK/record.err" || { cat "$WORK/record.err"; fail "case 3: record run failed"; }
diff -u "$WORK/live.out" "$WORK/record.out" || fail "case 3: record changed the answer"
[ "$(wc -l < "$WORK/record.cassette.jsonl" | tr -d ' ')" = "4" ] ||
  { cat "$WORK/record.cassette.jsonl"; fail "case 3: the cassette does not hold four exchanges"; }
grep -q '"method":"GET"' "$WORK/record.cassette.jsonl" || fail "case 3: the cassette has no method"
pass "3. record mode wrote four exchanges, and its answer matched live"

# ---- 4. replay needs no network ----------------------------------------
# bash 3.2 (macOS) has no ${arr[-1]}: indexing backwards silently becomes
# `kill 0`, which kills this script's whole process group (measured here —
# the same trap the repo noted once before). Kill by port instead.
for pid in $(lsof -ti ":$PORT" -sTCP:LISTEN 2>/dev/null); do kill "$pid" 2>/dev/null || true; done
sleep 0.3
# replay reads what record wrote (the paths differ only because the gate
# keeps one cassette per spec name)
cp "$WORK/record.cassette.jsonl" "$WORK/replay.cassette.jsonl"
write_spec "replay" "replay" ""
"$EXE" pipeline run --data-dir "$WORK/d-replay" --spec "$WORK/replay.json" \
  > "$WORK/replay.out" 2> "$WORK/replay.err" || { cat "$WORK/replay.err"; fail "case 4: replay failed with the peer down"; }
diff -u "$WORK/live.out" "$WORK/replay.out" ||
  fail "case 4: replay did not reproduce the live answer byte for byte"
pass "4. with the peer stopped, replay reproduced the live answer byte for byte"

# ---- 5. a cassette miss is refused by name -----------------------------
head -3 "$WORK/record.cassette.jsonl" > "$WORK/short.cassette.jsonl"
python3 - "$WORK/replay.json" "$WORK/short.cassette.jsonl" "$WORK/miss.json" <<'PY'
import json, sys
spec = json.load(open(sys.argv[1]))
spec['spec']['transforms'][0]['cassette'] = sys.argv[2]
spec['spec']['topic']['name'] = 'cars-miss'
json.dump(spec, open(sys.argv[3], 'w'), indent=2)
PY
"$EXE" pipeline run --data-dir "$WORK/d-miss" --spec "$WORK/miss.json" \
  > "$WORK/miss.out" 2> "$WORK/miss.err"
[ -s "$WORK/miss.out" ] && fail "case 5: a cassette miss still produced output"
grep -q "no cassette entry" "$WORK/miss.err" ||
  { cat "$WORK/miss.err"; fail "case 5: a cassette miss is not named"; }
pass "5. a cassette miss is refused by name, with no output (never an empty 200)"

# ---- 6. headers go out and credentials never go in ---------------------
SECRET="p32-secret-token"
cat > "$WORK/post.json" <<EOF
{
  "apiVersion": "moonflux.io/v1alpha1",
  "kind": "Pipeline",
  "metadata": { "name": "p32-post" },
  "spec": {
    "source": { "type": "file", "path": "$CARS" },
    "topic": { "name": "cars-post" },
    "transforms": [
      {
        "type": "callout",
        "method": "POST",
        "url": "http://127.0.0.1:$PORT/v1/chat",
        "body": "{\\"model\\":\\"{model}\\",\\"input\\":\\"{value}\\"}",
        "headers": { "Authorization": "Bearer \${P32_TOKEN}" },
        "mode": "record",
        "cassette": "$WORK/post.cassette.jsonl"
      }
    ],
    "sink": { "type": "stdout" }
  }
}
EOF
python3 scripts/http_mock.py --port "$PORT" --log "$WORK/post-requests.jsonl" > "$WORK/mock2.log" 2>&1 &
PIDS+=("$!")
wait_listen "$PORT" || { cat "$WORK/mock2.log"; fail "the mock peer did not restart"; }
P32_TOKEN="$SECRET" "$EXE" pipeline run --data-dir "$WORK/d-post" --spec "$WORK/post.json" \
  > "$WORK/post.out" 2> "$WORK/post.err" || { cat "$WORK/post.err"; fail "case 6: the POST callout failed"; }
grep -q "\"authorization\": \"Bearer $SECRET\"" "$WORK/post-requests.jsonl" ||
  { cat "$WORK/post-requests.jsonl"; fail "case 6: the peer never saw the Authorization header"; }
grep -q '"body": "{\\"model\\":\\"Camry\\"' "$WORK/post-requests.jsonl" ||
  { cat "$WORK/post-requests.jsonl"; fail "case 6: the POST body template did not fill from the record"; }
if grep -q "$SECRET" "$WORK/post.cassette.jsonl"; then
  fail "case 6: the credential was written into the cassette"
fi
grep -q '"method":"POST"' "$WORK/post.cassette.jsonl" || fail "case 6: the POST was not recorded"
pass "6. the peer saw the Authorization header and the filled body; the cassette holds neither token"

# ---- 7. the deadline is a bound, not a hope ----------------------------
cat > "$WORK/stall.json" <<EOF
{
  "apiVersion": "moonflux.io/v1alpha1",
  "kind": "Pipeline",
  "metadata": { "name": "p32-stall" },
  "spec": {
    "source": { "type": "file", "path": "$CARS" },
    "topic": { "name": "cars-stall" },
    "transforms": [
      {
        "type": "callout",
        "method": "GET",
        "url": "http://127.0.0.1:$PORT/stall",
        "mode": "live",
        "timeout_ms": 400
      }
    ],
    "sink": { "type": "stdout" }
  }
}
EOF
"$EXE" pipeline run --data-dir "$WORK/d-stall" --spec "$WORK/stall.json" \
  > "$WORK/stall.out" 2> "$WORK/stall.err"
[ -s "$WORK/stall.out" ] && fail "case 7: a stalled callout produced output"
grep -qE "recv|timeout|timed out" "$WORK/stall.err" ||
  { cat "$WORK/stall.err"; fail "case 7: the stalled call is not reported as a deadline"; }
pass "7. a stalling peer fails by name within the configured deadline, with no output"

# ---- 8. the plan says this is host IO ----------------------------------
"$EXE" pipeline plan -f "$WORK/replay.json" --data-dir "$WORK/d-plan" > "$WORK/plan.txt" 2>&1 ||
  { cat "$WORK/plan.txt"; fail "case 8: plan failed"; }
grep -q "host-io" "$WORK/plan.txt" || { cat "$WORK/plan.txt"; fail "case 8: the plan does not mark host IO"; }
grep -q "http callout: replay GET" "$WORK/plan.txt" ||
  { cat "$WORK/plan.txt"; fail "case 8: the plan does not describe the callout mode/method"; }
pass "8. the plan renders the callout as host IO with its mode and method"

# ---- 9. an ordinary pipeline still runs --------------------------------
printf 'the cat sat\n' > "$WORK/plain.txt"
cat > "$WORK/plain.json" <<EOF
{
  "apiVersion": "moonflux.io/v1alpha1",
  "kind": "Pipeline",
  "metadata": { "name": "p32-plain" },
  "spec": {
    "source": { "type": "file", "path": "$WORK/plain.txt" },
    "topic": { "name": "plain" },
    "transforms": [ { "type": "expr", "expr": "upper(value)" } ],
    "sink": { "type": "stdout" }
  }
}
EOF
"$EXE" pipeline run --data-dir "$WORK/d-plain" --spec "$WORK/plain.json" > "$WORK/plain.out" 2> "$WORK/plain.err" ||
  { cat "$WORK/plain.err"; fail "case 9: an ordinary pipeline failed"; }
check "9 ordinary pipeline" "$WORK/plain.out" "THE CAT SAT"
pass "9. a pipeline with no callout still runs: the callout changed no existing path"

echo "E2E-P32-CALLOUT: 9 legs green (host-side callouts, live/record/replay)"
