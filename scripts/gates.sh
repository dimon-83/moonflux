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

# interfaces must be regenerated with the code that changed them: a
# stale pkg.generated.mbti is how P15 shipped a whole round without
# filing its new public surface (caught in review, not by this gate —
# which is why this step exists)
step "moon info: interfaces are current" bash -c '
  moon info >/dev/null 2>&1
  stale=$(git status --porcelain -- "*pkg.generated.mbti")
  if [ -n "$stale" ]; then
    echo "pkg.generated.mbti is stale — run moon info and commit the diff:" >&2
    echo "$stale" >&2
    exit 1
  fi'

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

# The E2E gates below must test *this* build. They default to the debug
# binary for the same reason, and exporting it here makes that explicit
# rather than incidental.
export MOONFLUX_EXE="$ROOT/_build/native/debug/build/apps/cli/cli.exe"

# 4. gates
#
# Not in this list: scripts/e2e-p4-editor.sh. Its first half is
# mechanical (build, start the broker, assert on the segment file), but
# the milestone's gate is "a browser composes a pipeline and consumes
# data", and no shell script can press a button. Run it as:
#   scripts/e2e-p4-editor.sh setup    # prints the editor URL
#   … drive the page (agent or human) …
#   scripts/e2e-p4-editor.sh verify
step "crosscheck-protocol.sh" scripts/crosscheck-protocol.sh
if [ "$MODE" != "fast" ]; then
  step "e2e-p0.sh" scripts/e2e-p0.sh
  step "e2e-p0p.sh" scripts/e2e-p0p.sh
  step "e2e-p1-connectors.sh" scripts/e2e-p1-connectors.sh
  step "e2e-p1-rules.sh" scripts/e2e-p1-rules.sh
  step "e2e-p3-nodes.sh" scripts/e2e-p3-nodes.sh
  step "e2e-p3-replication.sh" scripts/e2e-p3-replication.sh
  step "e2e-p3-failover.sh" scripts/e2e-p3-failover.sh
  step "e2e-p3-metadata.sh" scripts/e2e-p3-metadata.sh
  step "e2e-p4-readmodes.sh" scripts/e2e-p4-readmodes.sh
  step "e2e-p4-ws.sh" scripts/e2e-p4-ws.sh
  step "e2e-p5-concurrency.sh" scripts/e2e-p5-concurrency.sh
  step "e2e-p5-partitions.sh" scripts/e2e-p5-partitions.sh
  step "e2e-p5-operator.sh" scripts/e2e-p5-operator.sh
  step "e2e-p6-functions.sh" scripts/e2e-p6-functions.sh
  step "e2e-p7-partitions.sh" scripts/e2e-p7-partitions.sh
  step "e2e-p8-storage.sh" scripts/e2e-p8-storage.sh
  step "e2e-p9-groups.sh" scripts/e2e-p9-groups.sh
  step "e2e-p11-assets.sh" scripts/e2e-p11-assets.sh
  step "e2e-p12-security.sh" scripts/e2e-p12-security.sh
  step "e2e-p13-control-plane.sh" scripts/e2e-p13-control-plane.sh
  step "e2e-p14-compaction.sh" scripts/e2e-p14-compaction.sh
  step "e2e-p15-bulk.sh" scripts/e2e-p15-bulk.sh
  step "e2e-p16-logcache.sh" scripts/e2e-p16-logcache.sh
  step "e2e-p17-bench.sh" scripts/e2e-p17-bench.sh
  step "e2e-p19-mqtt.sh" scripts/e2e-p19-mqtt.sh
  step "e2e-p20-kafka.sh" scripts/e2e-p20-kafka.sh
fi
step "crosscheck-operators.sh" scripts/crosscheck-operators.sh

printf '\n================ summary ================\n'
for label in "${PASSED[@]}"; do printf 'PASS  %s\n' "$label"; done
if [ "${#FAILED[@]}" -gt 0 ]; then
  for label in "${FAILED[@]}"; do printf 'FAIL  %s\n' "$label"; done
fi
printf '%d passed, %d failed\n' "${#PASSED[@]}" "${#FAILED[@]}"
[ "${#FAILED[@]}" -eq 0 ] || exit 1
