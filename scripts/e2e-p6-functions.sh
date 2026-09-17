#!/bin/bash
# P6 gate: function sets are versioned rule assets.
#
#   deploy (function-set create) -> list/get show a monotonic revision ->
#   a spec references the set by name and its expression calls the
#   custom function -> apply compiles it (a missing set, a name the set
#   does not define, and an impure body are all rejected at publish
#   time) -> records come back transformed -> updating the asset and
#   re-applying changes behavior, with the resolved revision visible in
#   topology.json. The server is never restarted.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# The debug build is what `moon build --target native` (and `moon test`)
# produce, so it is the artifact every gate here means to test. A release
# binary is only a fallback: preferring it once meant a gate silently
# tested a build from an earlier session.
EXE="${MOONFLUX_EXE:-$ROOT/_build/native/debug/build/apps/cli/cli.exe}"
[ -x "$EXE" ] || EXE="$ROOT/_build/native/release/build/apps/cli/cli.exe"
[ -x "$EXE" ] || { echo "cli executable not found; run: moon build --target native" >&2; exit 1; }

WORK="$(mktemp -d /tmp/moonflux-e2e-functions.XXXXXX)"
DATA="$WORK/data"
PORT="${MOONFLUX_FUNCTIONS_PORT:-19441}"
REMOTE="127.0.0.1:$PORT"
SERVER_PID=""
trap 'kill "$SERVER_PID" 2>/dev/null || true; rm -rf "$WORK"' EXIT

printf 'orange\nbanana\n' > "$WORK/in.txt"

fail() { echo "E2E-FUNCTIONS FAIL: $*" >&2; exit 1; }
pass() { echo "E2E-FUNCTIONS PASS: $*"; }

# the asset document: a set named textkit whose shout(x) is an
# expression body, exactly what `function-set create --file` consumes
write_asset() { # $1 = out path, $2 = body
  python3 - "$1" "$2" <<'PY'
import json, sys
doc = {
    "name": "textkit",
    "version": 1,
    "functions": [
        {"name": "shout", "params": ["x"], "body": sys.argv[2],
         "description": "uppercase and exclaim"},
    ],
}
open(sys.argv[1], "w").write(json.dumps(doc, indent=2))
PY
}

# a spec whose expr transform references a function set by name
write_spec() { # $1 = out path, $2 = expr, $3 = functions ("" = omit)
  python3 - "$1" "$2" "$3" "$WORK/in.txt" <<'PY'
import json, sys
transform = {"type": "expr", "expr": sys.argv[2]}
if sys.argv[3]:
    transform["functions"] = sys.argv[3]
doc = {
    "apiVersion": "moonflux.io/v1alpha1",
    "kind": "Pipeline",
    "metadata": {"name": "fn-demo"},
    "spec": {
        "source": {"type": "file", "path": sys.argv[4]},
        "transforms": [transform],
        "topic": {"name": "events"},
        "sink": {"type": "stdout"},
    },
}
open(sys.argv[1], "w").write(json.dumps(doc, indent=2))
PY
}

"$EXE" serve --data-dir "$DATA" --listen "$REMOTE" > "$WORK/serve.log" 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 50); do
  lsof -i ":$PORT" -sTCP:LISTEN >/dev/null 2>&1 && break
  sleep 0.1
done
lsof -i ":$PORT" -sTCP:LISTEN >/dev/null 2>&1 || fail "server did not start"

# ---------------------------------------------------------------- (5)
# a rule asset may not read the clock: determinism is what makes replay
# and golden comparison possible (AGENTS §5), so the body is rejected
# before it ever becomes an asset
write_asset "$WORK/fns-impure.json" 'now'
if "$EXE" function-set create --file "$WORK/fns-impure.json" --remote "$REMOTE" \
    > "$WORK/impure.out" 2>&1; then
  fail "an impure function body should be rejected at deploy"
fi
grep -qi "now" "$WORK/impure.out" || fail "impurity rejection lacks the reason"
pass "an impure body (clock builtin) is rejected at deploy"

# a document that says something the platform ignores is refused too
python3 - "$WORK/fns-unknown.json" <<'PY'
import json, sys
open(sys.argv[1], "w").write(json.dumps({
    "name": "textkit", "env": {}, "functions": [],
}))
PY
if "$EXE" function-set create --file "$WORK/fns-unknown.json" --remote "$REMOTE" \
    > /dev/null 2>&1; then
  fail "an asset with unknown fields should be rejected"
fi
pass "an asset document with unknown fields is rejected"

# ---------------------------------------------------------------- (1)
# deploy, and see it listed; a second deploy of the same name is an
# update of the same asset — one asset, a monotonic revision
write_asset "$WORK/fns-v1.json" 'upper(x) + "!"'
"$EXE" function-set create --file "$WORK/fns-v1.json" --remote "$REMOTE" \
  | grep -q "deployed function set textkit at revision 1" \
  || fail "first deploy did not report revision 1"
"$EXE" function-set list --remote "$REMOTE" | grep -q "textkit	revision=1" \
  || fail "list does not show the deployed set at revision 1"
"$EXE" function-set create --file "$WORK/fns-v1.json" --remote "$REMOTE" \
  | grep -q "updated function set textkit at revision 2" \
  || fail "re-deploy did not bump the revision"
"$EXE" function-set get --name textkit --remote "$REMOTE" | grep -q '"revision": 2' \
  || fail "get does not show the current revision"
"$EXE" function-set list --remote "$REMOTE" | grep -q "textkit	revision=2" \
  || fail "list does not show revision 2"
pass "function-set deploy/list/get carry a monotonic revision"

# ---------------------------------------------------------------- (3)
# the reference is checked at apply time: a spec naming a set that does
# not exist fails to apply, and no topology is written
write_spec "$WORK/spec-missing.json" 'shout(value)' 'nosuchset'
if "$EXE" pipeline apply -f "$WORK/spec-missing.json" --data-dir "$DATA" \
    > "$WORK/missing.out" 2>&1; then
  fail "a spec referencing a missing function set should be rejected"
fi
grep -q "no such function set nosuchset" "$WORK/missing.out" \
  || fail "missing-set rejection lacks the reason"
pass "a spec referencing a missing function set is rejected at apply"

# ---------------------------------------------------------------- (4)
# ... and so is a name the referenced set does not define: the set is
# registered before the publish-time static check, so unknown names are
# still caught where they always were
write_spec "$WORK/spec-outside.json" 'nosuch(value)' 'textkit'
if "$EXE" pipeline apply -f "$WORK/spec-outside.json" --data-dir "$DATA" \
    > "$WORK/outside.out" 2>&1; then
  fail "a function outside the referenced set should be rejected"
fi
grep -q "rejected" "$WORK/outside.out" || fail "out-of-set rejection lacks the reason"
pass "a function outside the referenced set is rejected at apply"

# ------------------------------------------------------------- surface
# the expression surface the compiled form accepts: a ternary is the
# conditional (measured — a top-level `if {}` block is a check-engine
# construct the compile stage rejects, ticket 36 §评估校核), so both
# halves are pinned here rather than left to folklore
write_spec "$WORK/spec-ternary.json" 'value == "orange" ? "yes" : "no"' ''
"$EXE" pipeline apply -f "$WORK/spec-ternary.json" --data-dir "$DATA" > /dev/null \
  || fail "a ternary expression should compile"
write_spec "$WORK/spec-ifblock.json" \
  'if value == "orange" { "yes" } else { "no" }' ''
if "$EXE" pipeline apply -f "$WORK/spec-ifblock.json" --data-dir "$DATA" \
    > "$WORK/ifblock.out" 2>&1; then
  fail "a top-level if-block should be rejected at apply"
fi
grep -q "rejected" "$WORK/ifblock.out" || fail "if-block rejection lacks the reason"
pass "the compiled expression surface takes ternaries, not top-level if-blocks"

# ---------------------------------------------------------------- (2)
# the good spec: the expression calls the custom function, and the
# records come back transformed — through the served path (hot reload)
# and through the single-process run path (same compiler)
write_spec "$WORK/spec-shout.json" 'shout(value)' 'textkit'
"$EXE" pipeline apply -f "$WORK/spec-shout.json" --data-dir "$DATA" > /dev/null \
  || fail "apply of a spec using a function set failed"
grep -q '"revision": 2' "$DATA/topology.json" \
  || fail "topology does not record the resolved function-set revision"

"$EXE" produce --topic events --file "$WORK/in.txt" --remote "$REMOTE" \
  | grep -q "offsets 0\.\.2" || fail "produce failed"
"$EXE" consume --topic events --remote "$REMOTE" | awk -F'\t' '{print $4}' > "$WORK/out1.txt" \
  || fail "consume failed"
printf 'ORANGE!\nBANANA!\n' > "$WORK/expect1.txt"
diff -u "$WORK/expect1.txt" "$WORK/out1.txt" || fail "custom-function transform output (served)"
kill -0 "$SERVER_PID" || fail "server restarted (must stay up)"
pass "a spec's expression calls the deployed custom function (served path)"

# the single-process run path resolves sets from its own data dir —
# function sets are node-local assets, so a runner gets a copy of the
# document (this is the per-node deployment posture, made explicit)
mkdir -p "$WORK/run-data"
cp "$DATA/metadata.json" "$WORK/run-data/metadata.json"
"$EXE" pipeline run --spec "$WORK/spec-shout.json" --data-dir "$WORK/run-data" \
  | awk -F'\t' '{print $1}' > "$WORK/out2.txt" || fail "pipeline run failed"
diff -u "$WORK/expect1.txt" "$WORK/out2.txt" || fail "custom-function transform output (run path)"
pass "the same rule executes on the single-process run path"

# ---------------------------------------------------------------- (6)
# update the asset and re-apply: the same spec text now compiles to the
# new revision and the stream changes — this is also why the revision
# is recorded in topology.json (a running pipeline is bound to the
# revision it was applied with)
write_asset "$WORK/fns-v2.json" 'upper(x) + "?"'
"$EXE" function-set create --file "$WORK/fns-v2.json" --remote "$REMOTE" \
  | grep -q "updated function set textkit at revision 3" \
  || fail "asset update did not report revision 3"

# until re-apply, the running rules are the ones already compiled
"$EXE" consume --topic events --remote "$REMOTE" | awk -F'\t' '{print $4}' > "$WORK/out3.txt" \
  || fail "consume after asset update failed"
diff -u "$WORK/expect1.txt" "$WORK/out3.txt" \
  || fail "rules changed without re-apply (the revision must be bound at apply)"

"$EXE" pipeline apply -f "$WORK/spec-shout.json" --data-dir "$DATA" > /dev/null \
  || fail "re-apply after asset update failed"
grep -q '"revision": 3' "$DATA/topology.json" \
  || fail "topology does not record revision 3 after re-apply"
"$EXE" consume --topic events --remote "$REMOTE" | awk -F'\t' '{print $4}' > "$WORK/out4.txt" \
  || fail "consume after re-apply failed"
printf 'ORANGE?\nBANANA?\n' > "$WORK/expect2.txt"
diff -u "$WORK/expect2.txt" "$WORK/out4.txt" || fail "re-applied rule output"
kill -0 "$SERVER_PID" || fail "server restarted (must stay up)"
pass "an asset update takes effect on re-apply, with the revision visible"

# cleanup: the asset is gone, and the reference fails again
"$EXE" function-set delete --name textkit --remote "$REMOTE" > /dev/null \
  || fail "delete failed"
if "$EXE" pipeline apply -f "$WORK/spec-shout.json" --data-dir "$DATA" > /dev/null 2>&1; then
  fail "apply should fail once the referenced set is deleted"
fi
pass "deleting the asset makes the next apply fail (no stale reference)"

kill "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true
echo "E2E-FUNCTIONS: all green"
