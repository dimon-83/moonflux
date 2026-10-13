#!/bin/bash
# Builds the operator guest modules (classic wasm target) and verifies
# their exported ABI surface. Artifacts land in _build/wasm/...; the
# probe reads the compiler-emitted WAT as ground truth.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "[1/3] building operator modules (wasm target)"

# The packages are NAMED, and the build runs twice ON PURPOSE. Both facts below
# were measured, and both were invisible until something built the operators from
# a PRISTINE tree — the Docker image build (decision 87) was the first thing in
# this repository to do that; every gate machine so far had a warm _build/ that
# hid them:
#
#   * a module-wide `moon build --target wasm` produced ZERO operator artifacts
#     in a cold tree (58 tasks, no .wasm, then "missing …"), so the artifact step
#     names the packages it needs;
#   * `--output-wat` emits ONLY the .wat in this toolchain and no .wasm at all,
#     while it KEEPS an existing .wasm — so the binary build goes first and the
#     WAT pass second. The probe reads the compiler-emitted WAT as ground truth
#     for the import section; the artifact under test is the .wasm.
OPS="operator-identity operator-upper operator-fixture operator-scalar operator-filter operator-flatmap operator-counter operator-wordkeys operator-tumble operator-probe operator-bankevents operator-balance operator-predicate operator-keyfield operator-loadtable operator-stolenplates operator-average operator-modelreq operator-subscribe operator-notify operator-keyconst operator-topwords operator-dedupe operator-stuck"
PKGS=""
for op in $OPS; do
  PKGS="$PKGS apps/$op"
done
moon build --target wasm $PKGS
moon build --target wasm --output-wat $PKGS

for op in $OPS; do
  WASM="_build/wasm/release/build/apps/$op/$op.wasm"
  [ -f "$WASM" ] || WASM="_build/wasm/debug/build/apps/$op/$op.wasm"
  [ -f "$WASM" ] || { echo "missing $WASM" >&2; exit 1; }
  # An artifact older than its own sources is a stale build wearing a
  # pass: the probe below would happily validate bytes nobody compiled
  # from this tree, and a test would report yesterday's behavior. The
  # `--output-wat` build has been observed to skip a package whose
  # sources changed, so this check is not theoretical.
  # the comparison covers the DEPENDENCY CLOSURE, not just this package:
  # an operator links the SDK and the kernel, so a change in apps/operator-sdk
  # or core/* makes its artifact stale without touching its own files
  # (measured the hard way while adding the SDK's json_field.mbt — the mtimes
  # landed in the same second and the check stayed green). We do not track the
  # dependency graph here: any core/apps source newer than the artifact means
  # "rebuild this package", which errs toward rebuilding.
  STALE="$(find core apps -newer "$WASM" \( -name '*.mbt' -o -name 'moon.pkg' \) -print -quit)"
  if [ -n "$STALE" ]; then
    # the module-wide --output-wat build skips a package whose sources
    # changed (observed while adding operator-counter), so rebuild it
    # explicitly — and if that still leaves the artifact older than its
    # sources, the gate fails rather than letting the probe bless bytes
    # nobody compiled from this tree
    echo "  $op: stale artifact — rebuilding this package"
    moon build --target wasm "apps/$op"
    # record that the artifact came from this tree. moonc is content-addressed,
    # so "no work to do" means the artifact already matches the sources — but
    # it leaves the mtime alone, and the check below would then report the same
    # package stale forever (measured immediately after adding this check).
    touch "$WASM"
    STALE="$(find core apps -newer "$WASM" \( -name '*.mbt' -o -name 'moon.pkg' \) -print -quit)"
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
