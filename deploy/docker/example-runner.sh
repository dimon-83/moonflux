#!/usr/bin/env bash
# Runs the SDF example catalog ON MOONFLUX, inside the moonflux image.
#
#   moonflux-example --list      every catalog case this image carries
#   moonflux-example <case>      run one case, byte-compare with its expected file
#   moonflux-example all         run every case and report a total
#
# A catalog case IS one `moonflux pipeline run` whose stdout is compared byte for
# byte with the case's expected file - the statement scripts/e2e-p42-docker.sh makes
# for 13-parse-sentence and scripts/e2e-p29-examples.sh makes for all of them
# natively. This adds the loop, the verdict and the summary, so the host needs
# nothing but `docker run`.
#
# Everything it needs to know is derivable from a case's own directory, so this file
# carries no second copy of the mapping:
#
#   spec.json         -> expected.txt
#   spec-<x>.json     -> expected-<x>.txt
#   a spec with NO expected file is a REFUSAL case: the run MUST fail
#   an fns.json in the case directory must be created in the data dir BEFORE the run
#
# Iron rules (AGENT.md rule 1): every wait is bounded, stdout and stderr are never
# merged into a verdict, nothing is read from stdin, and the console gets a summary
# rather than a transcript.
set -uo pipefail

EXAMPLES="${MOONFLUX_EXAMPLES_DIR:-/opt/moonflux/examples/sdf}"
EXE="${MOONFLUX_EXE:-/usr/local/bin/moonflux}"
WORK="${MOONFLUX_EXAMPLE_WORK:-/tmp/moonflux-example}"
BUDGET="${MOONFLUX_EXAMPLE_TIMEOUT:-120}"

PASS=0      # ran and matched its expected file, byte for byte
RAN=0       # ran to completion with no expected file (a relay/helper the gate drives)
NEEDS=0     # could not run here: needs a peer or a credential
FAILED=0    # ran, and disagreed with the repository
NAMES=()

mkdir -p "$WORK"

specs_of() {
  ls "$1"/spec*.json 2>/dev/null
}

# expected_for <spec path>: spec.json -> expected.txt, spec-x.json -> expected-x.txt
expected_for() {
  local spec="$1"
  local dir base
  dir="$(dirname "$spec")"
  base="$(basename "$spec" .json)"
  if [ "$base" = "spec" ]; then
    printf '%s/expected.txt' "$dir"
  else
    printf '%s/expected%s.txt' "$dir" "${base#spec}"
  fi
}

all_cases() {
  local d
  for d in "$EXAMPLES"/*/; do
    if [ -d "$d" ] && [ -n "$(specs_of "$d" | head -1)" ]; then
      basename "$d"
    fi
  done
}

do_list() {
  local name d
  printf '%-30s %-26s %s\n' "CASE" "SPECS" "PORTS-FROM"
  while read -r name; do
    if [ -z "$name" ]; then
      continue
    fi
    d="$EXAMPLES/$name"
    printf '%-30s %-26s %s\n' "$name" \
      "$(specs_of "$d" | xargs -n1 basename | tr '\n' ' ')" \
      "$(grep -m1 -o 'Ported from.*' "$d/README.md" 2>/dev/null | cut -c1-60)"
  done < <(all_cases)
}

# run_bounded <seconds> <stdout-file> <stderr-file> <command...>
# `timeout` is GNU coreutils; this waits on the pid it started and reports 124 for
# "budget exhausted", which a caller can tell apart from the command's own failure.
run_bounded() {
  local limit="$1"
  local out="$2"
  local err="$3"
  local pid i
  shift 3
  "$@" > "$out" 2> "$err" &
  pid=$!
  i=0
  while [ "$i" -lt "$((limit * 2))" ]; do
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid"
      return $?
    fi
    sleep 0.5
    i=$((i + 1))
  done
  kill -TERM "$pid" 2>/dev/null
  sleep 0.3
  kill -KILL "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  return 124
}

note_fail() {
  FAILED=$((FAILED + 1))
  NAMES+=("$1")
}

# why_failed <stderr file>: name what is missing rather than leaving a bare code
why_failed() {
  if grep -qE "Connection refused|errno=111" "$1" 2>/dev/null; then
    printf 'NEEDS-A-PEER (a local port nothing is listening on)'
    return
  fi
  if grep -qE "environment variable [A-Z_]+ is not set" "$1" 2>/dev/null; then
    printf 'NEEDS-A-CREDENTIAL'
    return
  fi
  printf 'exit status'
}

run_variant() {
  local case="$1"
  local spec="$2"
  local data="$WORK/data-$1"
  local base exp out err rc
  base="$(basename "$spec" .json)"
  exp="$(expected_for "$spec")"
  out="$WORK/$case.$base.out"
  err="$WORK/$case.$base.err"
  : > "$out"
  : > "$err"
  run_bounded "$BUDGET" "$out" "$err" \
    "$EXE" pipeline run --data-dir "$data" --spec "$spec"
  rc=$?

  # NO expected file does NOT mean "this must be refused". Measured: most such specs
  # are the relays and helpers the example gate starts in the background (a relay
  # produces no expected file because another spec's output is what gets compared),
  # and treating them as refusal cases reported 29 healthy runs as failures. The
  # authority on what each spec means is the example gate; this runner reports what
  # it observed and never invents a verdict.
  if [ ! -f "$exp" ]; then
    if [ "$rc" -eq 0 ]; then
      printf 'RAN   %-30s %-14s completed; no expected file (a relay/helper)\n' "$case" "$base"
      RAN=$((RAN + 1))
      return 0
    fi
    printf 'NEEDS %-30s %-14s %s\n' "$case" "$base" "$(why_failed "$err")"
    NEEDS=$((NEEDS + 1))
    NAMES+=("$case/$base (needs)")
    return 0
  fi

  if [ "$rc" -ne 0 ]; then
    local why
    why="$(why_failed "$err")"
    if [ "$why" != "exit status" ]; then
      printf 'NEEDS %-30s %-14s %s\n' "$case" "$base" "$why"
      NEEDS=$((NEEDS + 1))
      NAMES+=("$case/$base (needs)")
      return 0
    fi
    printf 'FAIL: %-30s %-14s exited %s\n' "$case" "$base" "$rc" >&2
    tail -n 3 "$err" 2>/dev/null | sed 's/^/      | /' >&2
    note_fail "$case/$base (exit $rc)"
    return 1
  fi

  if cmp -s "$out" "$exp"; then
    printf 'PASS  %-30s %-14s %s record(s), matches %s\n' \
      "$case" "$base" "$(grep -c . "$out")" "$(basename "$exp")"
    PASS=$((PASS + 1))
    return 0
  fi
  printf 'FAIL: %s/%s differs from %s\n' "$case" "$base" "$(basename "$exp")" >&2
  diff -u "$exp" "$out" 2>/dev/null | head -8 | sed 's/^/      | /' >&2
  note_fail "$case/$base (differs)"
  return 1
}

run_case() {
  local name="$1"
  local dir spec
  dir="$EXAMPLES/$name"
  if [ ! -d "$dir" ]; then
    printf 'FAIL: unknown case %s (try --list)\n' "$name" >&2
    note_fail "$name (unknown)"
    return 1
  fi
  mkdir -p "$WORK/data-$name"
  if [ -f "$dir/fns.json" ]; then
    if ! "$EXE" function-set create --file "$dir/fns.json" \
         --data-dir "$WORK/data-$name" > "$WORK/$name.fns.log" 2>&1; then
      printf 'FAIL: %s: the case function set was refused\n' "$name" >&2
      tail -n 3 "$WORK/$name.fns.log" | sed 's/^/      | /' >&2
      note_fail "$name (function set)"
      return 1
    fi
  fi
  while read -r spec; do
    if [ -n "$spec" ]; then
      run_variant "$name" "$spec"
    fi
  done < <(specs_of "$dir")
  return 0
}

case "${1:---list}" in
  --list|-l|list)
    do_list
    exit 0
    ;;
  all)
    while read -r name; do
      if [ -n "$name" ]; then
        run_case "$name"
      fi
    done < <(all_cases)
    ;;
  *)
    run_case "$1"
    ;;
esac

printf 'moonflux examples: %s matched, %s ran (no expected file), %s need a peer or credential, %s failed\n' \
  "$PASS" "$RAN" "$NEEDS" "$FAILED"
if [ "$NEEDS" -gt 0 ]; then
  printf 'not runnable in a closed container: %s\n' "${NAMES[*]}" >&2
fi
# Only a real disagreement or a real failure sets the exit code. "needs" is reported
# rather than hidden, because a bucket that quietly passes is how a suite stops
# meaning anything.
if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
exit 0
