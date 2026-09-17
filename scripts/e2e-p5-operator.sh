#!/bin/bash
# P5 gate: operator management — the CLI verifies modules through the
# *production host*, so what passes here is what the data path would
# accept, with no second, softer checker.
#
#   1. a good module verifies (ABI v1 handshake + init round trip)
#   2. garbage is refused with the parse reason
#   3. describe reports the ABI version and the budget envelope from
#      core/operator's own constants
#   4. list shows every built operator with its health
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# The debug build is what `moon build --target native` (and `moon test`)
# produce, so it is the artifact every gate here means to test. A release
# binary is only a fallback: preferring it once meant a gate silently
# tested a build from an earlier session.
EXE="${MOONFLUX_EXE:-$ROOT/_build/native/debug/build/apps/cli/cli.exe}"
[ -x "$EXE" ] || EXE="$ROOT/_build/native/release/build/apps/cli/cli.exe"
[ -x "$EXE" ] || { echo "cli executable not found; run: moon build --target native" >&2; exit 1; }

WORK="$(mktemp -d /tmp/moonflux-p5-operator.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "E2E-P5-OPERATOR FAIL: $*" >&2; exit 1; }
pass() { echo "E2E-P5-OPERATOR PASS: $*"; }

# artifacts: the gate builds them rather than trusting a stale tree
"$ROOT/scripts/build-operators.sh" > "$WORK/build.log" 2>&1 \
  || { cat "$WORK/build.log"; fail "build-operators.sh"; }
UPPER="$(find "$ROOT/_build/wasm" -name operator-upper.wasm | head -1)"
[ -n "$UPPER" ] || fail "no operator-upper artifact"

# ---- 1. a good module verifies -----------------------------------------
"$EXE" operator verify --file "$UPPER" > "$WORK/verify.out" 2>&1 \
  || { cat "$WORK/verify.out"; fail "the good module failed to verify"; }
grep -q "speaks ABI v1 and accepted init" "$WORK/verify.out" \
  || { cat "$WORK/verify.out"; fail "the verify output does not say what passed"; }
pass "a good module verifies through the production host"

# ---- 2. garbage is refused, with the reason ----------------------------
printf 'this is not wasm' > "$WORK/bad.wasm"
if "$EXE" operator verify --file "$WORK/bad.wasm" > "$WORK/bad.out" 2>&1; then
  fail "garbage must not verify"
fi
grep -q "magic header" "$WORK/bad.out" \
  || { cat "$WORK/bad.out"; fail "the refusal does not say why"; }
pass "garbage is refused with the parse reason"

# ---- 3. describe reports the enforced budget, from the kernel ----------
"$EXE" operator describe --file "$UPPER" > "$WORK/describe.out" 2>&1 \
  || { cat "$WORK/describe.out"; fail "describe failed"; }
grep -q "abi_version 1" "$WORK/describe.out" || { cat "$WORK/describe.out"; fail "no ABI version"; }
# the numbers must equal core/operator's constants (this grep is the
# drift alarm: change the kernel, the gate makes you update the doc)
grep -q "internal: 100000 records / 50000000 fuel" "$WORK/describe.out" \
  || { cat "$WORK/describe.out"; fail "the internal budget does not match core/operator"; }
grep -q "tenant: 1000 records / 2000000 fuel" "$WORK/describe.out" \
  || { cat "$WORK/describe.out"; fail "the tenant budget does not match core/operator"; }
pass "describe reports the ABI version and the enforced budget tiers"

# the wall clock is a report, not a gate (README 决策 33): the module
# surface must say so, and verify must actually time a call
"$EXE" operator describe --file "$UPPER" | grep -q "report-only" \
  || fail "describe does not say the wall-clock numbers are report-only"
"$EXE" operator describe --file "$UPPER" | grep -q "fuel is the reproducible budget" \
  || fail "describe does not explain what enforces the budget"
"$EXE" operator verify --file "$UPPER" | grep -q "reported, not enforced" \
  || fail "verify does not report its timing as an observation"
pass "the wall clock is documented (and timed) as an observation, never a gate"

# ---- 4. list shows health, not just names ------------------------------
OUT="$("$EXE" operator list)"
printf '%s\n' "$OUT" | grep -q "operator-upper	ok" || { printf '%s\n' "$OUT"; fail "operator-upper is not listed ok"; }
printf '%s\n' "$OUT" | grep -q "operator-identity	ok" \
  || { printf '%s\n' "$OUT"; fail "operator-identity is not listed ok"; }
printf '%s\n' "$OUT" | grep -q "operator-fixture	ok" \
  || { printf '%s\n' "$OUT"; fail "operator-fixture is not listed ok"; }
pass "list verifies every artifact and reports per-module health"

echo "E2E-P5-OPERATOR: all green"
