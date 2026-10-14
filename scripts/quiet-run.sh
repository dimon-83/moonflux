#!/bin/bash
# quiet-run.sh <logfile> <command...> — run a noisy command, print a bounded tail.
#
# Why this exists (decision 99): the failure mode was not a big file on disk, it
# was a long session re-rendering every build/test/CI line into a client's
# renderer until the renderer's memory ran out. A file written to disk costs
# nothing; the same text drawn into a panel costs memory that is never released.
# So the rule for heavy commands is: capture to a file, print only what a human
# or an agent needs to decide the next step, and leave the rest readable.
#
#   scripts/quiet-run.sh /tmp/build.log moon build --target native apps/cli
#   scripts/quiet-run.sh /tmp/test.log moon test --target wasm core/codec
#   MOONFLUX_QUIET_TAIL=80 scripts/quiet-run.sh /tmp/t.log moon test
#
# On success it prints one line. On failure it prints one line, the exit code,
# and the last MOONFLUX_QUIET_TAIL lines (default 20) of the log, prefixed with
# "| " so the quoted output is unmistakable.
set -uo pipefail

log="${1:?usage: quiet-run.sh <logfile> <command...>}"
shift
[ "$#" -gt 0 ] || { echo "quiet-run.sh: no command given" >&2; exit 2; }
tail_lines="${MOONFLUX_QUIET_TAIL:-20}"

start="$(date +%s)"
if "$@" > "$log" 2>&1; then
  code=0
else
  code=$?
fi
elapsed="$(( $(date +%s) - start ))"
lines="$(wc -l < "$log" | tr -d ' ')"
if [ "$code" -eq 0 ]; then
  printf 'PASS  %ss  %s lines  %s\n' "$elapsed" "$lines" "$log"
else
  printf 'FAIL  exit=%s  %ss  %s lines  %s\n' "$code" "$elapsed" "$lines" "$log"
  tail -n "$tail_lines" "$log" | sed 's/^/      | /'
fi
exit "$code"
