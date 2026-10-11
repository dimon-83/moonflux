#!/bin/bash
# Builds the operator guest modules (classic wasm target) and verifies
# their exported ABI surface. Artifacts land in _build/wasm/...; the
# probe reads the compiler-emitted WAT as ground truth.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "[1/3] building operator modules (wasm target)"
moon build --target wasm --output-wat
for op in operator-identity operator-upper operator-fixture operator-scalar operator-filter operator-flatmap operator-counter operator-wordkeys operator-tumble operator-probe operator-bankevents operator-balance; do
  WASM="_build/wasm/release/build/apps/$op/$op.wasm"
  [ -f "$WASM" ] || WASM="_build/wasm/debug/build/apps/$op/$op.wasm"
  [ -f "$WASM" ] || { echo "missing $WASM" >&2; exit 1; }
  # An artifact older than its own sources is a stale build wearing a
  # pass: the probe below would happily validate bytes nobody compiled
  # from this tree, and a test would report yesterday's behavior. The
  # `--output-wat` build has been observed to skip a package whose
  # sources changed, so this check is not theoretical.
  STALE="$(find "apps/$op" -newer "$WASM" \( -name '*.mbt' -o -name 'moon.pkg' \) -print -quit)"
  if [ -n "$STALE" ]; then
    # the module-wide --output-wat build skips a package whose sources
    # changed (observed while adding operator-counter), so rebuild it
    # explicitly — and if that still leaves the artifact older than its
    # sources, the gate fails rather than letting the probe bless bytes
    # nobody compiled from this tree
    echo "  $op: stale artifact — rebuilding this package"
    moon build --target wasm "apps/$op"
    STALE="$(find "apps/$op" -newer "$WASM" \( -name '*.mbt' -o -name 'moon.pkg' \) -print -quit)"
    if [ -n "$STALE" ]; then
      echo "  $op: STALE artifact ($WASM is older than $STALE) after a rebuild" >&2
      exit 1
    fi
  fi
  echo "  $op: $(wc -c < "$WASM" | tr -d ' ') bytes"
done

echo "[2/3] probing exported ABI surface (mf_op_* signatures)"
python3 tools/probe_operator_exports.py

echo "[3/3] operator behavior unit tests (native, same semantics)"
moon test --target native apps/operator-sdk

echo "BUILD-OPERATORS: all green"
