#!/bin/bash
# P0' gate: one PipelineSpec compiles to a runnable process topology
# and `pipeline plan` previews the diff.
#   write spec -> plan (full create) -> apply -> change spec ->
#   plan (update diff) -> apply -> run -> output equals source file
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# The debug build is what `moon build --target native` (and `moon test`)
# produce, so it is the artifact every gate here means to test. A release
# binary is only a fallback: preferring it once meant a gate silently
# tested a build from an earlier session.
EXE="${MOONFLUX_EXE:-$ROOT/_build/native/debug/build/apps/cli/cli.exe}"
[ -x "$EXE" ] || EXE="$ROOT/_build/native/release/build/apps/cli/cli.exe"
[ -x "$EXE" ] || { echo "cli executable not found; run: moon build --target native" >&2; exit 1; }

WORK="$(mktemp -d /tmp/moonflux-e2e-p0p.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

DATA="$WORK/data"

printf 'one\ntwo\nthree\n' > "$WORK/input-a.txt"
printf 'alpha\nbeta\n' > "$WORK/input-b.txt"

make_spec() { # $1 = source path, $2 = out file
  cat > "$2" <<EOF
{
  "apiVersion": "moonflux.io/v1alpha1",
  "kind": "Pipeline",
  "metadata": { "name": "file-to-stdout" },
  "spec": {
    "source": { "type": "file", "path": "$1" },
    "transforms": [],
    "topic": { "name": "events" },
    "sink": { "type": "stdout" }
  }
}
EOF
}

fail() { echo "E2E-P0P FAIL: $*" >&2; exit 1; }
pass() { echo "E2E-P0P PASS: $*"; }

make_spec "$WORK/input-a.txt" "$WORK/spec-a.json"
make_spec "$WORK/input-b.txt" "$WORK/spec-b.json"

# invalid spec must fail loudly with structured error lines
cat > "$WORK/spec-bad.json" <<EOF
{"apiVersion": "moonflux.io/v1alpha1", "kind": "Deployment", "metadata": {"name": "x"},
 "spec": {"source": {"type": "file", "path": "p"}, "topic": {"name": "t"}, "sink": {"type": "stdout"}}}
EOF
if "$EXE" pipeline plan -f "$WORK/spec-bad.json" --data-dir "$DATA" > "$WORK/invalid.out" 2>&1; then
  fail "invalid spec should exit non-zero"
fi
grep -q "spec error" "$WORK/invalid.out" || fail "invalid spec output lacks error report"
grep -q "bad-kind" "$WORK/invalid.out" || fail "invalid spec output lacks code"
pass "invalid spec rejected with structured errors"

# plan with nothing applied: full create
"$EXE" pipeline plan -f "$WORK/spec-a.json" --data-dir "$DATA" > "$WORK/plan1.txt" \
  || fail "plan (create) exited non-zero"
grep -q "applied state: none (full create)" "$WORK/plan1.txt" || fail "plan1 missing full-create line"
grep -q "diff: 3 to add, 0 to update, 0 to remove" "$WORK/plan1.txt" || fail "plan1 diff counts"
grep -q "source-runner \[native\] (source-runner): file source: $WORK/input-a.txt" "$WORK/plan1.txt" \
  || fail "plan1 process listing"
# plan must not persist anything
[ ! -f "$DATA/topology.json" ] || fail "plan wrote topology.json"
pass "plan compiles spec to topology and previews full create (no persist)"

# apply, then plan again: no changes
"$EXE" pipeline apply -f "$WORK/spec-a.json" --data-dir "$DATA" > /dev/null \
  || fail "apply (a) exited non-zero"
[ -f "$DATA/topology.json" ] || fail "apply did not persist topology.json"
"$EXE" pipeline plan -f "$WORK/spec-a.json" --data-dir "$DATA" > "$WORK/plan2.txt" \
  || fail "plan (no-op) exited non-zero"
grep -q "diff: 0 to add, 0 to update, 0 to remove" "$WORK/plan2.txt" || fail "no-op plan diff"
pass "applied state persists; second plan reports no changes"

# change the source path: plan shows a field-level update
"$EXE" pipeline plan -f "$WORK/spec-b.json" --data-dir "$DATA" > "$WORK/plan3.txt" \
  || fail "plan (update) exited non-zero"
grep -q "~ source-runner: file source: $WORK/input-a.txt -> file source: $WORK/input-b.txt" "$WORK/plan3.txt" \
  || fail "update diff missing"
pass "changed spec diffs as one field-level update"

"$EXE" pipeline apply -f "$WORK/spec-b.json" --data-dir "$DATA" > /dev/null \
  || fail "apply (b) exited non-zero"

# run the applied pipeline: stdout sink output equals source file
"$EXE" pipeline run --name file-to-stdout --data-dir "$DATA" > "$WORK/run.txt" \
  || fail "run exited non-zero"
diff -u "$WORK/input-b.txt" "$WORK/run.txt" || fail "run output != source file"
pass "run executes the compiled topology: file -> topic -> stdout matches"

echo "E2E-P0P: all green"
