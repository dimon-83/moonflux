#!/bin/bash
# P2 gate: operator semantics crosscheck + fail-closed sandbox paths.
#
# Semantic leg — the SAME golden records run through two independent
# implementations of the same transform and must produce byte-identical
# output:
#   (a) mbel `upper(value)` / `value`  (native MoonBit expression engine)
#   (b) operator-upper.wasm / operator-identity.wasm (wasm guest, ABI v1)
# The wasm leg runs in-process through wasmtime; the data file
# scripts/testdata/operator-golden.txt is the shared source of truth.
#
# Fail-closed leg — the sandbox fixture operator is driven into each
# failure mode and the host must report a structured error, emit no
# partial output, and stay bounded:
#   refuse -> status != 0 with the guest's own message
#   trap   -> wasm trap surfaces as an error
#   spin   -> fuel budget stops it (deterministic, no clock)
#
# Server leg — the same chain runs on the served consumption path
# (moonflux serve), so "operators are part of the data path" covers
# both the single-process run and the long-lived server.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# The debug build is what `moon build --target native` (and `moon test`)
# produce, so it is the artifact every gate here means to test. A release
# binary is only a fallback: preferring it once meant a gate silently
# tested a build from an earlier session.
EXE="${MOONFLUX_EXE:-$ROOT/_build/native/debug/build/apps/cli/cli.exe}"
[ -x "$EXE" ] || EXE="$ROOT/_build/native/release/build/apps/cli/cli.exe"
[ -x "$EXE" ] || { echo "cli executable not found; run: moon build --target native" >&2; exit 1; }

GOLDEN="$ROOT/scripts/testdata/operator-golden.txt"
WORK="$(mktemp -d /tmp/moonflux-operators.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "CROSSCHECK-OPERATORS FAIL: $*" >&2; exit 1; }
pass() { echo "CROSSCHECK-OPERATORS PASS: $*"; }

# 0. golden data is generated, not hand-edited
python3 "$ROOT/tools/gen_operator_golden.py" --check > /dev/null \
  || fail "golden data is stale (run tools/gen_operator_golden.py)"

# 1. artifacts: CLI + operator modules (WAT probe asserts the ABI surface)
moon build --target native --release > /dev/null 2>&1 || true
"$ROOT/scripts/build-operators.sh" > "$WORK/build.log" 2>&1 \
  || { cat "$WORK/build.log"; fail "build-operators.sh"; }

op_wasm() { # $1 = operator package name
  local f="$ROOT/_build/wasm/release/build/apps/$1/$1.wasm"
  [ -f "$f" ] || f="$ROOT/_build/wasm/debug/build/apps/$1/$1.wasm"
  [ -f "$f" ] || fail "missing wasm artifact for $1"
  echo "$f"
}

UPPER_WASM="$(op_wasm operator-upper)"
IDENT_WASM="$(op_wasm operator-identity)"
FIXTURE_WASM="$(op_wasm operator-fixture)"

# spec <out> <transform-json>  (source fixed to the golden file)
spec() {
  cat > "$1" <<EOF
{
  "apiVersion": "moonflux.io/v1alpha1",
  "kind": "Pipeline",
  "metadata": { "name": "operator-crosscheck" },
  "spec": {
    "source": { "type": "file", "path": "$GOLDEN" },
    "transforms": [ $2 ],
    "topic": { "name": "golden" },
    "sink": { "type": "stdout" }
  }
}
EOF
}

run_spec() { # $1 = spec, $2 = data dir, $3 = stdout file
  "$EXE" pipeline run --spec "$1" --data-dir "$2" > "$3" 2> "$3.err"
}

# The CLI reports failures on stdout ("error: ..."), so the failure legs
# grep stdout+stderr together, require a structured error, and require
# that NO record from the source stream was emitted (fail-closed: a
# batch that fails the chain is never half-written to the sink).
run_expect_fail() { # $1 = spec, $2 = data dir, $3 = combined log
  set +e
  "$EXE" pipeline run --spec "$1" --data-dir "$2" > "$3" 2>&1
  local rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "$(basename "$1"): expected a non-zero exit"
  grep -q '^error:' "$3" || { cat "$3"; fail "$(basename "$1"): no structured error"; }
  local leaked
  leaked="$(grep -Fxf "$WORK/out-baseline.txt" "$3" || true)"
  [ -z "$leaked" ] || {
    cat "$3"
    fail "$(basename "$1"): emitted records despite failing"
  }
}

# ---------------------------------------------------------------- semantic
# 2. uppercase: mbel upper(value) vs wasm operator-upper
spec "$WORK/spec-upper-mbel.json" '{ "type": "expr", "expr": "upper(value)" }'
spec "$WORK/spec-upper-wasm.json" \
  "{ \"type\": \"wasm\", \"module\": \"$UPPER_WASM\" }"

run_spec "$WORK/spec-upper-mbel.json" "$WORK/d-mbel" "$WORK/out-upper-mbel.txt" \
  || { cat "$WORK/out-upper-mbel.txt.err"; fail "mbel upper leg"; }
run_spec "$WORK/spec-upper-wasm.json" "$WORK/d-wasm" "$WORK/out-upper-wasm.txt" \
  || { cat "$WORK/out-upper-wasm.txt.err"; fail "wasm upper leg"; }

[ -s "$WORK/out-upper-mbel.txt" ] || fail "mbel leg produced no output"
diff -u "$WORK/out-upper-mbel.txt" "$WORK/out-upper-wasm.txt" \
  || fail "upper: native and wasm outputs differ"
pass "upper: mbel upper(value) == wasm operator-upper ($(wc -l < "$WORK/out-upper-mbel.txt" | tr -d ' ') records, byte-identical)"

# 3. identity: mbel value vs wasm operator-identity, both against the
#    un-transformed stream (text sources skip blank lines by design, so
#    the raw file is not the right expectation — the baseline is)
spec "$WORK/spec-ident-mbel.json" '{ "type": "expr", "expr": "value" }'
spec "$WORK/spec-ident-wasm.json" \
  "{ \"type\": \"wasm\", \"module\": \"$IDENT_WASM\" }"
spec "$WORK/spec-baseline.json" ""

run_spec "$WORK/spec-baseline.json" "$WORK/d-base" "$WORK/out-baseline.txt" \
  || { cat "$WORK/out-baseline.txt.err"; fail "baseline leg"; }
run_spec "$WORK/spec-ident-mbel.json" "$WORK/d-idm" "$WORK/out-ident-mbel.txt" \
  || { cat "$WORK/out-ident-mbel.txt.err"; fail "mbel identity leg"; }
run_spec "$WORK/spec-ident-wasm.json" "$WORK/d-idw" "$WORK/out-ident-wasm.txt" \
  || { cat "$WORK/out-ident-wasm.txt.err"; fail "wasm identity leg"; }

diff -u "$WORK/out-baseline.txt" "$WORK/out-ident-mbel.txt" \
  || fail "identity: mbel value changed the stream"
diff -u "$WORK/out-baseline.txt" "$WORK/out-ident-wasm.txt" \
  || fail "identity: wasm operator did not pass records through unchanged"
pass "identity: wasm operator-identity is a byte-exact passthrough of the source stream"

# 4. the fixture's default mode is the positive control for the failure legs
spec "$WORK/spec-fix-ok.json" \
  "{ \"type\": \"wasm\", \"module\": \"$FIXTURE_WASM\", \"config\": {\"mode\": \"identity\"} }"
run_spec "$WORK/spec-fix-ok.json" "$WORK/d-fix-ok" "$WORK/out-fix-ok.txt" \
  || { cat "$WORK/out-fix-ok.txt.err"; fail "fixture identity control"; }
diff -u "$WORK/out-baseline.txt" "$WORK/out-fix-ok.txt" \
  || fail "fixture identity control output"
pass "fixture control: config-injected operator runs the same chain"

# --------------------------------------------------------------- fail-closed
# 5. refusal: the guest says no -> structured error carrying its message,
#    and nothing downstream is emitted (records are not silently dropped)
spec "$WORK/spec-fix-refuse.json" \
  "{ \"type\": \"wasm\", \"module\": \"$FIXTURE_WASM\", \"config\": {\"mode\": \"refuse\"} }"
run_expect_fail "$WORK/spec-fix-refuse.json" "$WORK/d-refuse" "$WORK/out-refuse.txt"
grep -q "fixture refused this batch on purpose" "$WORK/out-refuse.txt" \
  || { cat "$WORK/out-refuse.txt"; fail "refusal lost the guest's message"; }
pass "refuse: guest status != 0 -> structured error, no partial output"

# 6. refusal at init: a config the operator rejects fails at instantiate
spec "$WORK/spec-fix-badcfg.json" \
  "{ \"type\": \"wasm\", \"module\": \"$FIXTURE_WASM\", \"config\": {\"mode\": \"nonsense\"} }"
run_expect_fail "$WORK/spec-fix-badcfg.json" "$WORK/d-badcfg" "$WORK/out-badcfg.txt"
grep -q "rejected its config" "$WORK/out-badcfg.txt" \
  || { cat "$WORK/out-badcfg.txt"; fail "bad config error lacks the reason"; }
pass "init: operator-rejected config -> structured error before any call"

# 7. trap: an uncontrolled guest failure surfaces as an error
spec "$WORK/spec-fix-trap.json" \
  "{ \"type\": \"wasm\", \"module\": \"$FIXTURE_WASM\", \"config\": {\"mode\": \"trap\"} }"
run_expect_fail "$WORK/spec-fix-trap.json" "$WORK/d-trap" "$WORK/out-trap.txt"
grep -qi "trap\|unreachable" "$WORK/out-trap.txt" \
  || { cat "$WORK/out-trap.txt"; fail "trap error lacks a trap indication"; }
pass "trap: guest trap -> structured error, no partial output"

# 8. runaway: the fuel budget stops it and the run stays bounded
spec "$WORK/spec-fix-spin.json" \
  "{ \"type\": \"wasm\", \"module\": \"$FIXTURE_WASM\", \"config\": {\"mode\": \"spin\"} }"
START=$SECONDS
run_expect_fail "$WORK/spec-fix-spin.json" "$WORK/d-spin" "$WORK/out-spin.txt"
ELAPSED=$((SECONDS - START))
grep -q "fuel budget" "$WORK/out-spin.txt" \
  || { cat "$WORK/out-spin.txt"; fail "runaway was not reported as a budget error"; }
[ "$ELAPSED" -lt 30 ] || fail "runaway took ${ELAPSED}s (budget not enforced)"
pass "spin: fuel budget stops a runaway operator in ${ELAPSED}s (deterministic cap, no clock)"

# ------------------------------------------------------------------ server
# 9. the served consumption path runs the same wasm chain: apply the
#    wasm-uppercase pipeline, produce the golden file, consume it back
PORT="${MOONFLUX_OPERATORS_PORT:-19341}"
SERVER_PID=""
cleanup_server() {
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true
  [ -n "$SERVER_PID" ] && wait "$SERVER_PID" 2>/dev/null || true
}
trap 'cleanup_server; rm -rf "$WORK"' EXIT

"$EXE" pipeline apply -f "$WORK/spec-upper-wasm.json" --data-dir "$WORK/d-serve" > /dev/null \
  || fail "apply (wasm upper) failed"
"$EXE" serve --data-dir "$WORK/d-serve" --listen "127.0.0.1:$PORT" > "$WORK/serve.log" 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 50); do
  lsof -i ":$PORT" -sTCP:LISTEN > /dev/null 2>&1 && break
  sleep 0.1
done
lsof -i ":$PORT" -sTCP:LISTEN > /dev/null 2>&1 || { cat "$WORK/serve.log"; fail "server did not start"; }

"$EXE" produce --topic golden --file "$GOLDEN" --remote "127.0.0.1:$PORT" > "$WORK/produce.log" \
  || { cat "$WORK/produce.log"; fail "produce to the served pipeline"; }
# consume prints offset<TAB>timestamp<TAB>key<TAB>value; `cut -f4-`
# (not awk) because a record value may itself contain tabs
"$EXE" consume --topic golden --remote "127.0.0.1:$PORT" | cut -f4- > "$WORK/out-serve.txt" \
  || fail "consume from the served pipeline"

diff -u "$WORK/out-upper-wasm.txt" "$WORK/out-serve.txt" \
  || fail "served path output differs from the run path output"
# and it is genuinely transformed, not a passthrough that happens to
# match (the baseline is the un-transformed stream)
if diff -q "$WORK/out-baseline.txt" "$WORK/out-serve.txt" > /dev/null; then
  fail "served path returned untransformed records"
fi
pass "serve: the served consumption path runs the same wasm operator chain"

cleanup_server
SERVER_PID=""

echo "CROSSCHECK-OPERATORS: all green"
