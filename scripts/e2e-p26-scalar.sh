#!/bin/bash
# E2E-P26: ABI v2 scalar calls — untrusted scalar functions in the
# sandbox, end to end.
#
#    1. a scalar transform runs: `{"type":"scalar","function":"shout"}`
#       resolves against the node's registry, the module is called per
#       record through the v2 exports, and the output is the guest's
#    2. crosscheck: the SAME transformation expressed as an mbel
#       `upper(value)` rule is byte-identical to the sandboxed guest's
#       output (two engines, one answer)
#    3. an unregistered function name is refused AT APPLY, naming the
#       registry path
#    4. a v1-only module registered as a scalar function is refused at
#       apply with "ABI v1-only" — the pair check, not a runtime mystery
#    5. a type mismatch (a string value reaching a number parameter) is
#       a structured run failure with no output
#    6. the per-batch call ceiling refuses a batch that exceeds it
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
EXE="${MOONFLUX_EXE:-$ROOT/_build/native/debug/build/apps/cli/cli.exe}"
[ -x "$EXE" ] || EXE="$ROOT/_build/native/release/build/apps/cli/cli.exe"
[ -x "$EXE" ] || {
  echo "cli executable not found; run: moon build --target native" >&2
  exit 1
}

SCALAR_WASM=""
for candidate in \
  "_build/wasm/release/build/apps/operator-scalar/operator-scalar.wasm" \
  "_build/wasm/debug/build/apps/operator-scalar/operator-scalar.wasm"; do
  [ -f "$candidate" ] && SCALAR_WASM="$ROOT/$candidate" && break
done
V1_WASM=""
for candidate in \
  "_build/wasm/release/build/apps/operator-upper/operator-upper.wasm" \
  "_build/wasm/debug/build/apps/operator-upper/operator-upper.wasm"; do
  [ -f "$candidate" ] && V1_WASM="$ROOT/$candidate" && break
done
[ -n "$SCALAR_WASM" ] || { echo "operator-scalar.wasm missing; run: scripts/build-operators.sh" >&2; exit 1; }
[ -n "$V1_WASM" ] || { echo "operator-upper.wasm missing; run: scripts/build-operators.sh" >&2; exit 1; }

WORK="$(mktemp -d /tmp/moonflux-p26-scalar.XXXXXX)"
trap 'if [ "${MOONFLUX_KEEP:-0}" = "1" ]; then echo "keeping $WORK"; else rm -rf "$WORK"; fi' EXIT

fail() { echo "E2E-P26 FAIL: $1" >&2; exit 1; }
pass() { echo "E2E-P26 PASS: $1"; }

printf 'hello sandbox\nmixed Case text\nfinal line\n' > "$WORK/in.txt"

write_registry() { # $1 = shout's per-batch ceiling (default 100000)
  local ceiling="${1:-100000}"
  cat > "$WORK/data/scalar-functions.json" <<JSON
{"revision":1,"functions":[
  {"name":"shout","module":"$SCALAR_WASM","tier":"user","max_calls_per_batch":$ceiling},
  {"name":"tax","module":"$SCALAR_WASM","tier":"user","max_calls_per_batch":100000},
  {"name":"double","module":"$SCALAR_WASM","tier":"user","max_calls_per_batch":100000},
  {"name":"v1only","module":"$V1_WASM","tier":"user","max_calls_per_batch":100000}
]}
JSON
}

write_spec() { # $1 = path, $2 = name, $3 = transform json, $4 = sink json
  printf '{"apiVersion":"moonflux.io/v1alpha1","kind":"Pipeline","metadata":{"name":"%s"},"spec":{"source":{"type":"file","path":"%s"},"topic":{"name":"p26-events"},"transforms":[%s],"sink":%s}}\n' \
    "$2" "$WORK/in.txt" "$3" "$4" > "$1"
}

mkdir -p "$WORK/data"
write_registry

# ---- 1. the scalar transform runs ---------------------------------------
write_spec "$WORK/scalar.json" p26-scalar \
  '{"type":"scalar","function":"shout"}' '{"type":"stdout"}'
"$EXE" pipeline apply --data-dir "$WORK/data" --file "$WORK/scalar.json" > /dev/null \
  || fail "apply of the scalar spec failed"
"$EXE" pipeline run --data-dir "$WORK/data" > "$WORK/scalar.out" 2>"$WORK/scalar.err" \
  || { cat "$WORK/scalar.err"; fail "the scalar run failed"; }
EXPECTED="$(printf 'HELLO SANDBOX\nMIXED CASE TEXT\nFINAL LINE')"
[ "$(cat "$WORK/scalar.out")" = "$EXPECTED" ] \
  || { echo "got:"; cat "$WORK/scalar.out"; fail "the guest's scalar output is wrong"; }
pass "1: the sandboxed scalar function ran per record through ABI v2"

# ---- 2. crosscheck: mbel upper() vs the guest ---------------------------
write_spec "$WORK/mbel.json" p26-mbel \
  '{"type":"expr","expr":"upper(value)"}' '{"type":"stdout"}'
"$EXE" pipeline apply --data-dir "$WORK/data" --file "$WORK/mbel.json" > /dev/null \
  || fail "apply of the mbel spec failed"
"$EXE" pipeline run --data-dir "$WORK/data" > "$WORK/mbel.out" 2>"$WORK/mbel.err" \
  || { cat "$WORK/mbel.err"; fail "the mbel reference run failed"; }
cmp -s "$WORK/scalar.out" "$WORK/mbel.out" \
  || { diff "$WORK/scalar.out" "$WORK/mbel.out"; fail "the guest and mbel disagree on the same transformation"; }
pass "2: the sandboxed guest is byte-identical to mbel's upper() on the same input"

# ---- 3. an unregistered name is refused at apply ------------------------
write_spec "$WORK/nope.json" p26-nope \
  '{"type":"scalar","function":"nope"}' '{"type":"stdout"}'
if "$EXE" pipeline apply --data-dir "$WORK/data" --file "$WORK/nope.json" > "$WORK/nope.out" 2>&1; then
  fail "an unregistered scalar function was accepted at apply"
fi
grep -q "not registered" "$WORK/nope.out" \
  || { cat "$WORK/nope.out"; fail "the refusal does not say the name is unregistered"; }
grep -q "scalar-functions.json" "$WORK/nope.out" \
  || fail "the refusal does not name the registry"
pass "3: an unregistered function is refused at apply, naming the registry"

# ---- 4. a v1-only module cannot serve scalar calls ----------------------
write_spec "$WORK/v1.json" p26-v1only \
  '{"type":"scalar","function":"v1only"}' '{"type":"stdout"}'
if "$EXE" pipeline apply --data-dir "$WORK/data" --file "$WORK/v1.json" > "$WORK/v1.out" 2>&1; then
  fail "a v1-only module was accepted as a scalar function"
fi
grep -q "ABI v1-only" "$WORK/v1.out" \
  || { cat "$WORK/v1.out"; fail "the refusal does not say the module is v1-only"; }
pass "4: a v1-only module registered as scalar is refused at apply (the pair check)"

# ---- 5. a type mismatch is a structured run failure ---------------------
# "double" declares one NUMBER parameter; the transform hands it the
# record's value as a string, so the guest's kind check must refuse it
write_spec "$WORK/double.json" p26-double \
  '{"type":"scalar","function":"double"}' '{"type":"stdout"}'
"$EXE" pipeline apply --data-dir "$WORK/data" --file "$WORK/double.json" > /dev/null \
  || fail "apply of the double spec failed (binding is legal; only the DATA is wrong)"
if "$EXE" pipeline run --data-dir "$WORK/data" > "$WORK/double.out" 2> "$WORK/double.err"; then
  fail "a string reaching a number parameter was accepted"
fi
grep -q "must be number" "$WORK/double.err" \
  || { cat "$WORK/double.err"; fail "the type refusal does not name the expectation"; }
[ -s "$WORK/double.out" ] && { cat "$WORK/double.out"; fail "a failed scalar batch produced output"; }
pass "5: a type mismatch fails structured, with no output (fail-closed)"

# ---- 6. the per-batch call ceiling --------------------------------------
# shout's registered ceiling drops to 2 and the input holds 3 records:
# the ceiling refuses the batch before any evaluation happens
write_registry 2
write_spec "$WORK/ceil.json" p26-ceiling \
  '{"type":"scalar","function":"shout"}' '{"type":"stdout"}'
"$EXE" pipeline apply --data-dir "$WORK/data" --file "$WORK/ceil.json" > /dev/null \
  || fail "apply of the ceiling spec failed"
if "$EXE" pipeline run --data-dir "$WORK/data" > "$WORK/ceil.out" 2> "$WORK/ceil.err"; then
  fail "a batch over the registered call ceiling was accepted"
fi
grep -q "exceeds its registered ceiling" "$WORK/ceil.err" \
  || { cat "$WORK/ceil.err"; fail "the ceiling refusal does not say what was exceeded"; }
pass "6: the registered per-batch call ceiling refuses an oversized batch"

echo "E2E-P26-SCALAR PASS: 6 legs green"
