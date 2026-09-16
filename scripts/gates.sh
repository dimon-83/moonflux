#!/bin/bash
# All moonflux gates, in dependency order — the one command that answers
# "is the current milestone still green?".
#
# Each gate is independently runnable and self-describing; this script
# only sequences them and reports a summary, so a failure points at the
# gate to open, not at this file.
#
# Usage:
#   scripts/gates.sh              # everything
#   scripts/gates.sh fast         # skip the E2E gates (still builds + tests)
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

MODE="${1:-full}"
FAILED=()
PASSED=()
step() { # $1 = label, rest = command
  local label="$1"
  shift
  printf '\n=== %s ===\n' "$label"
  if "$@"; then
    PASSED+=("$label")
  else
    FAILED+=("$label")
  fi
}

# 1. static: formatting, generated artifacts, four-backend matrix
step "moon fmt --check" moon fmt --check

step "generated artifacts are current" bash -c '
  python3 tools/gen_spec_corpus.py --check &&
  python3 tools/gen_protocol_vectors.py --check &&
  python3 tools/gen_operator_golden.py --check'

for target in wasm wasm-gc js native; do
  step "moon build --target $target" bash -c "
    out=\$(moon build --target $target 2>&1)
    echo \"\$out\" | grep -E '^Error' && exit 1
    exit 0"
done

# 2. tests: the kernel must pass on at least two backends (AGENTS §6)
step "moon test --target native" moon test --target native
step "moon test --target wasm-gc" moon test --target wasm-gc

# 3. operator artifacts + ABI surface
step "build-operators.sh" scripts/build-operators.sh

# 4. gates
step "crosscheck-protocol.sh" scripts/crosscheck-protocol.sh
if [ "$MODE" != "fast" ]; then
  step "e2e-p0.sh" scripts/e2e-p0.sh
  step "e2e-p0p.sh" scripts/e2e-p0p.sh
  step "e2e-p1-connectors.sh" scripts/e2e-p1-connectors.sh
  step "e2e-p1-rules.sh" scripts/e2e-p1-rules.sh
  step "e2e-p3-nodes.sh" scripts/e2e-p3-nodes.sh
  step "e2e-p3-replication.sh" scripts/e2e-p3-replication.sh
fi
step "crosscheck-operators.sh" scripts/crosscheck-operators.sh

printf '\n================ summary ================\n'
for label in "${PASSED[@]}"; do printf 'PASS  %s\n' "$label"; done
if [ "${#FAILED[@]}" -gt 0 ]; then
  for label in "${FAILED[@]}"; do printf 'FAIL  %s\n' "$label"; done
fi
printf '%d passed, %d failed\n' "${#PASSED[@]}" "${#FAILED[@]}"
[ "${#FAILED[@]}" -eq 0 ] || exit 1
