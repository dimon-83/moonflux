#!/bin/bash
# P1 gate: rule changes take effect in seconds.
#   apply(upper) -> produce -> consume shows transformed data ->
#   change spec -> apply (NO server restart) -> consume shows the NEW
#   rule's output. Invalid rules are rejected at apply time and the
#   previous rules stay active.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# The debug build is what `moon build --target native` (and `moon test`)
# produce, so it is the artifact every gate here means to test. A release
# binary is only a fallback: preferring it once meant a gate silently
# tested a build from an earlier session.
EXE="${MOONFLUX_EXE:-$ROOT/_build/native/debug/build/apps/cli/cli.exe}"
[ -x "$EXE" ] || EXE="$ROOT/_build/native/release/build/apps/cli/cli.exe"
[ -x "$EXE" ] || { echo "cli executable not found; run: moon build --target native" >&2; exit 1; }

WORK="$(mktemp -d /tmp/moonflux-e2e-rules.XXXXXX)"
PORT="${MOONFLUX_RULES_PORT:-19331}"
SERVER_PID=""
trap 'kill "$SERVER_PID" 2>/dev/null || true; rm -rf "$WORK"' EXIT

DATA="$WORK/data"
printf 'orange\nbanana\n' > "$WORK/in.txt"

make_spec() { # $1 = expr, $2 = out
  local expr_json
  expr_json="$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1")"
  cat > "$2" <<EOF
{
  "apiVersion": "moonflux.io/v1alpha1",
  "kind": "Pipeline",
  "metadata": { "name": "rule-demo" },
  "spec": {
    "source": { "type": "file", "path": "$WORK/in.txt" },
    "transforms": [ { "type": "expr", "expr": $expr_json } ],
    "topic": { "name": "events" },
    "sink": { "type": "stdout" }
  }
}
EOF
}

fail() { echo "E2E-RULES FAIL: $*" >&2; exit 1; }
pass() { echo "E2E-RULES PASS: $*"; }

# invalid rules are rejected at publish time (apply), never applied
make_spec 'nosuchfn(value)' "$WORK/spec-bad.json"
if "$EXE" pipeline apply -f "$WORK/spec-bad.json" --data-dir "$DATA" > "$WORK/bad.out" 2>&1; then
  fail "invalid transform should be rejected at apply"
fi
grep -q "rejected" "$WORK/bad.out" || fail "apply rejection lacks reason"
pass "publish-time static check rejects bad rules"

# ---- T108: the probe names a shape the expression declares --------------
# A fixed literal probe claimed the record was not JSON, so fromJSON(value)
# was rejected before any record flowed. The probe now builds a JSON object
# out of the literals the expression itself names: field access publishes,
# while every literal, type and name rejection stays.
printf '{"name":"Alice","ssn":"123-45-6789"}\n{"name":"Bob","ssn":"987-65-4321"}\n' > "$WORK/ssn.txt"
ssn_spec() { # $1 = expr, $2 = out
  local expr_json
  expr_json="$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1")"
  cat > "$2" <<EOF
{
  "apiVersion": "moonflux.io/v1alpha1",
  "kind": "Pipeline",
  "metadata": { "name": "json-fields" },
  "spec": {
    "source": { "type": "file", "path": "$WORK/ssn.txt" },
    "transforms": [ { "type": "expr", "expr": $expr_json } ],
    "topic": { "name": "ssn-events" },
    "sink": { "type": "stdout" }
  }
}
EOF
}

ssn_spec 'replace(get(fromJSON(value), "ssn"), "-", "*")' "$WORK/spec-ssn.json"
"$EXE" pipeline run --data-dir "$WORK/ssn-data" --spec "$WORK/spec-ssn.json" \
  > "$WORK/ssn.out" 2> "$WORK/ssn.err" ||
  { cat "$WORK/ssn.err"; fail "JSON field access should publish and run"; }
printf '123*45*6789\n987*65*4321\n' > "$WORK/ssn.expect"
diff -u "$WORK/ssn.expect" "$WORK/ssn.out" || fail "field access output"
pass "the publish-time probe accepts JSON field access the expression names (T108)"

for bad in 'fromJSON("a")' 'get(fromJSON(value), "ssn") + 1' 'fromJSON_missing(value)'; do
  ssn_spec "$bad" "$WORK/spec-bad-json.json"
  if "$EXE" pipeline apply -f "$WORK/spec-bad-json.json" --data-dir "$WORK/bad-json-data" \
    > "$WORK/bad-json.out" 2>&1; then
    fail "the widened probe must still reject: $bad"
  fi
  grep -q "rejected" "$WORK/bad-json.out" || fail "rejection of '$bad' lacks reason"
done
pass "the widened probe keeps the literal / type / name rejections (T108)"

# valid rule: uppercase the value
make_spec 'upper(value)' "$WORK/spec-upper.json"
"$EXE" pipeline apply -f "$WORK/spec-upper.json" --data-dir "$DATA" > /dev/null \
  || fail "apply (upper) failed"

"$EXE" serve --data-dir "$DATA" --listen "127.0.0.1:$PORT" > "$WORK/serve.log" 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 50); do
  lsof -i ":$PORT" -sTCP:LISTEN >/dev/null 2>&1 && break
  sleep 0.1
done
lsof -i ":$PORT" -sTCP:LISTEN >/dev/null 2>&1 || fail "server did not start"
SERVER_START_STAMP=$(stat -f '%m' "$WORK/data/topology.json" 2>/dev/null || echo 0)

# feed data through the file source path
"$EXE" produce --topic events --file "$WORK/in.txt" --remote "127.0.0.1:$PORT" \
  | grep -q "offsets 0\.\.2" || fail "produce failed"

# consume through the served rule: uppercased
"$EXE" consume --topic events --remote "127.0.0.1:$PORT" | awk -F'\t' '{print $4}' > "$WORK/out1.txt" \
  || fail "consume (upper) failed"
printf 'ORANGE\nBANANA\n' > "$WORK/expect1.txt"
diff -u "$WORK/expect1.txt" "$WORK/out1.txt" || fail "upper rule output"
pass "rule v1 (upper) transforms the stream"

# change the rule and apply — the server keeps running
make_spec 'value + "-v2"' "$WORK/spec-v2.json"
"$EXE" pipeline apply -f "$WORK/spec-v2.json" --data-dir "$DATA" > /dev/null \
  || fail "apply (v2) failed"

# no restart: same process serves the new rule on the next request
"$EXE" consume --topic events --remote "127.0.0.1:$PORT" | awk -F'\t' '{print $4}' > "$WORK/out2.txt" \
  || fail "consume (v2) failed"
printf 'orange-v2\nbanana-v2\n' > "$WORK/expect2.txt"
diff -u "$WORK/expect2.txt" "$WORK/out2.txt" || fail "v2 rule output"
kill -0 "$SERVER_PID" || fail "server restarted (must stay up)"
pass "rule v2 hot-swapped into the running server (same PID)"

# the same rules execute on the single-process run path (--spec direct)
"$EXE" pipeline run --spec "$WORK/spec-v2.json" --data-dir "$WORK/run-data" | awk -F'\t' '{print $1}' > "$WORK/out3.txt" \
  || fail "pipeline run with transform failed"
diff -u "$WORK/expect2.txt" "$WORK/out3.txt" || fail "pipeline run transform output"
pass "pipeline run --spec executes the same transform chain"

kill "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true
echo "E2E-RULES: all green"
