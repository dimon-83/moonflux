#!/bin/bash
# gates-bg.sh [mode] — run the gate suite DETACHED and print where to watch it.
#
# Why this exists (decision 101): a suite run must not be able to take its caller
# down. The failure mode we hit is pipe inheritance — a gate starts a server, the
# server inherits the caller's stdout/stderr, the gate is killed or times out, and
# the server keeps the pipe open. The caller (a terminal, a CI step, an agent's
# client) then waits for a pipe that a daemon it never started still holds:
# measured symptom was a tool call that never returned and a client that died
# with it.
#
# So the launcher detaches all three standard streams, and the suite's own `step`
# gives every gate its own process group with a watchdog. Run heavy suites
# through here; poll the log in short commands instead of waiting in one.
#
#   scripts/gates-bg.sh              # full suite, detached
#   scripts/gates-bg.sh fast         # the fast subset, detached
#   tail -f "$(cat /tmp/moonflux-gates.last)"        # watch it (Ctrl-C is safe)
#   tail -3 "$(cat /tmp/moonflux-gates.last)"        # or just peek
#
# The per-step full logs live in the directory printed as "gates logdir".
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:-full}"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="${MOONFLUX_GATES_BG_LOG:-/tmp/moonflux-gates-$MODE-$STAMP.log}"
LOGDIR="${MOONFLUX_GATES_LOGDIR:-/tmp/moonflux-gates-steps-$STAMP}"

cd "$ROOT"
# stdin, stdout and stderr all detached: nothing the suite spawns inherits this
# shell's streams, and this command returns immediately
nohup env MOONFLUX_GATES_LOGDIR="$LOGDIR" "$ROOT/scripts/gates.sh" "$MODE" \
  </dev/null > "$LOG" 2>&1 &
PID=$!
disown "$PID" 2>/dev/null || true
printf '%s\n' "$LOG" > /tmp/moonflux-gates.last
printf 'gates: %s (detached, pid %s)\n' "$MODE" "$PID"
printf 'gates log:   %s\n' "$LOG"
printf 'gates logdir: %s\n' "$LOGDIR"
printf 'watch with:  tail -f %s\n' "$LOG"
