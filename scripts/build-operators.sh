#!/bin/bash
# Builds the operator guest modules (classic wasm target) and verifies
# their exported ABI surface. Artifacts land in _build/wasm/...; the
# probe reads the compiler-emitted WAT as ground truth.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "[1/3] building operator modules (wasm target)"
moon build --target wasm --output-wat
for op in operator-identity operator-upper; do
  WASM="_build/wasm/release/build/apps/$op/$op.wasm"
  [ -f "$WASM" ] || WASM="_build/wasm/debug/build/apps/$op/$op.wasm"
  [ -f "$WASM" ] || { echo "missing $WASM" >&2; exit 1; }
  echo "  $op: $(wc -c < "$WASM" | tr -d ' ') bytes"
done

echo "[2/3] probing exported ABI surface (mf_op_* signatures)"
python3 tools/probe_operator_exports.py

echo "[3/3] operator behavior unit tests (native, same semantics)"
moon test --target native apps/operator-sdk

echo "BUILD-OPERATORS: all green"
