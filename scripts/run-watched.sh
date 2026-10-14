#!/bin/bash
# run-watched.sh <samples-file> <command...> — run a command under resource sampling.
#
# Why: a long cluster run that is suspected of eating the machine cannot be
# diagnosed after the fact unless somebody wrote the numbers down WHILE it ran.
# This starts scripts/resource-watch.sh, runs the command, stops the watch, and
# prints a bounded summary of the samples next to the command's own log.
#
# The numbers are REPORTED, never gated — the same rule as the benchmarks
# (decision 41): a workload must not pass on an idle laptop and fail on a loaded
# CI runner. RAM, process counts and the client's resident size are that kind of
# number. What is gated is the STRUCTURE: no leaked children, no unbounded waits,
# no inherited pipes (scripts/audit-gate-hygiene.py, AGENT.md rule 1).
#
#   scripts/run-watched.sh /tmp/rw.log bash scripts/e2e-p49-docker-cluster.sh
set -uo pipefail

samples="${1:?usage: run-watched.sh <samples-file> <command...>}"
shift
[ "$#" -gt 0 ] || { echo "run-watched.sh: no command given" >&2; exit 2; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
interval="${MOONFLUX_WATCH_INTERVAL:-2}"

# detached, and its own output goes nowhere: this is a witness, not a participant
"$ROOT/scripts/resource-watch.sh" "$samples" "$interval" </dev/null >/dev/null 2>&1 &
watch_pid=$!

"$@"
status=$?

kill "$watch_pid" 2>/dev/null
wait "$watch_pid" 2>/dev/null

printf '\n---- resource watch: %s (interval %ss) ----\n' "$samples" "$interval"
awk -F'\t' 'NR > 1 {
    n++
    if (minfree == 0 || $3 < minfree) minfree = $3
    if ($5 > maxproc) maxproc = $5
    if ($6 > maxw) maxw = $6
    if ($7 > maxwr) maxwr = $7
    if ($9 > maxclient) maxclient = $9
    if ($2 > maxload) maxload = $2
    if ($4 > maxswap) maxswap = $4
  }
  END {
    if (n == 0) { print "no samples (the watch did not start)"; exit }
    printf "samples=%d over ~%d min\n", n, n * 2 / 60
    printf "workload peak:   %d process(es), %d MB\n", maxw, maxwr
    printf "free memory min: %d MB\n", minfree
    printf "processes peak:  %d   swap peak: %d MB   load peak: %s\n", maxproc, maxswap, maxload
    printf "client peak RSS: %d MB\n", maxclient
    print "                 (the editor/harness, watched on purpose: what runs out"
    print "                  is an Electron renderer heap, not system memory)"
  }' "$samples"

exit "$status"
