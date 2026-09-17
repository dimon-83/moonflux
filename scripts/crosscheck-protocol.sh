#!/bin/bash
# P0 gate: protocol sample crosscheck.
#   1. vectors_gen.mbt matches the JSON source of truth (--check)
#   2. the current encoder reproduces the checked-in golden bytes
#   3. kernel tests (incl. golden-vector crosschecks) pass on native
# Exits non-zero on any drift.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "[1/3] vectors_gen.mbt vs testdata/protocol_vectors.json"
python3 tools/gen_protocol_vectors.py --check

echo "[2/3] vectortool output vs checked-in vectors"
VECTOOL="$ROOT/_build/native/debug/build/apps/vectortool/vectortool.exe"
[ -x "$VECTOOL" ] || VECTOOL="$ROOT/_build/native/release/build/apps/vectortool/vectortool.exe"
if [ ! -x "$VECTOOL" ]; then
  echo "vectortool not built; run: moon build --target native" >&2
  exit 1
fi
"$VECTOOL" | diff -u core/protocol/testdata/protocol_vectors.json - \
  || { echo "encoder drift: vectortool output differs from testdata" >&2; exit 1; }

echo "[3/3] native test suite (golden vectors + corruption injection)"
moon test --target native

echo "CROSSCHECK-P0: all green"
