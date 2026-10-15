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
#
# OUTPUT BUDGET (decision 99). This suite is run many times a day, and every
# run's output is rendered again wherever it is watched: a terminal, a CI log
# view, an agent's transcript. Measured on the way in: a full run printed ~770
# lines to the console, and the same 770 lines were re-rendered on every rerun —
# that repeated rendering, not any single file, is what exhausted a client's
# renderer. So the default is a SUMMARY: each step writes its full output to a
# log file, the console gets one line per step, and a failing step gets a
# bounded tail plus the path to its full log. Nothing is lost — it is on disk.
#
#   MOONFLUX_GATES_VERBOSE=1   stream every step's output (the old behaviour)
#   MOONFLUX_GATES_TAIL=N      lines of a failing step's log to show (default 25)
#   MOONFLUX_GATES_LOGDIR=D    where the per-step logs go
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

MODE="${1:-full}"
FAILED=()
PASSED=()
VERBOSE="${MOONFLUX_GATES_VERBOSE:-0}"
TAIL_LINES="${MOONFLUX_GATES_TAIL:-25}"
LOGDIR="${MOONFLUX_GATES_LOGDIR:-}"
if [ -z "$LOGDIR" ]; then
  LOGDIR="$(mktemp -d /tmp/moonflux-gates.XXXXXX)"
fi
mkdir -p "$LOGDIR"

# A foreground terminal is how a caller gets exposed to every pipe a leaked gate
# spawns (AGENT.md rule 1): the caller waits for a pipe held by a daemon it never
# started. CI has no TTY and must keep working, so this is a nudge, not a
# refusal — the same reason the hygiene audit is static rather than a runtime
# check.
if [ -t 1 ] && [ "${MOONFLUX_GATES_FOREGROUND_OK:-0}" != "1" ]; then
  printf 'note: this is a foreground terminal. Heavy runs belong in scripts/gates-bg.sh\n' >&2
  printf '      (detached: nothing a gate spawns can hold this terminal open).\n' >&2
  printf '      set MOONFLUX_GATES_FOREGROUND_OK=1 to silence this.\n' >&2
fi

step() { # $1 = label, rest = command
  local label="$1"
  shift
  local slug log start elapsed
  slug="$(printf '%s' "$label" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-60)"
  log="$LOGDIR/$slug.log"
  if [ "$VERBOSE" = "1" ]; then
    printf '\n=== %s ===\n' "$label"
    # pipefail (set above) makes the pipeline carry the STEP's status, not tee's
    if "$@" 2>&1 | tee "$log"; then
      PASSED+=("$label")
    else
      FAILED+=("$label")
    fi
    return
  fi
  start="$(date +%s)"
  # Two things this shape buys, and both are about a step not taking its caller
  # down with it:
  #
  #   * `</dev/null` + `> log`: nothing a gate spawns inherits THIS script's
  #     stdin/stdout. That inheritance is how a suite run becomes a hung terminal
  #     or a crashed client — the caller waits for a pipe that a daemon it never
  #     started still holds open.
  #   * `set -m` in the subshell + a watchdog: each step is its own process
  #     GROUP, so a step that hangs is reaped whole (`kill -- -PID`) instead of
  #     leaving children behind to hold the pipes the step was handed. Measured
  #     reason: a suite run that outlived its own tool call left the caller
  #     waiting on exactly those pipes.
  ( set -m; "$@" ) </dev/null > "$log" 2>&1 &
  local pid=$!
  local waited=0 status=0 limit="${MOONFLUX_GATES_STEP_TIMEOUT:-900}"
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$limit" ]; then
      elapsed="$(( $(date +%s) - start ))"
      FAILED+=("$label (timeout)")
      printf 'FAIL  %-40s %4ss  TIMEOUT after %ss, killing its process group  %s\n' \
        "$label" "$elapsed" "$limit" "$log"
      tail -n "$TAIL_LINES" "$log" | sed 's/^/      | /'
      kill -TERM -"$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null
      sleep 2
      kill -9 -"$pid" 2>/dev/null || kill -9 "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      return
    fi
    sleep 1
    waited=$((waited + 1))
  done
  wait "$pid"
  status=$?
  elapsed="$(( $(date +%s) - start ))"
  if [ "$status" -eq 0 ]; then
    PASSED+=("$label")
    # the preview prefers the gate's own verdict over whatever line happens to
    # be last (a shell job-control notice like "Killed: 9" is not a verdict)
    local preview
    preview="$(grep -E 'PASS:|FAIL:|all green|passed, [0-9]+ failed|Total tests' "$log" |
      tail -n 1 | tr -d '\r' | cut -c1-58)"
    [ -n "$preview" ] || preview="$(tail -n 1 "$log" | tr -d '\r' | cut -c1-58)"
    printf 'PASS  %-40s %4ss  %s\n' "$label" "$elapsed" "$preview"
  else
    FAILED+=("$label")
    printf 'FAIL  %-40s %4ss  %s\n' "$label" "$elapsed" "$log"
    tail -n "$TAIL_LINES" "$log" | sed 's/^/      | /'
  fi
}

# 1. static: formatting, generated artifacts, four-backend matrix
step "moon fmt --check" moon fmt --check

# A gate must not feed a spec through /dev/stdin (P34, decision 75).
#
# Why this is a static check rather than a comment: bash implements
# here-documents differently per platform — macOS's bash 3.2 materialises them
# as temp files, bash 5.1+ (Linux CI) uses a pipe — and `read_file` sizes the
# file before reading it, so on Linux the spec arrives as "0 bytes" and the
# apply fails. Eleven gates died silently that way on the Linux full run (the
# failure was invisible because stdout was redirected and `set -e` exited).
# A platform-dependent death that says nothing is worth a five-line guard.
step "audit-flags.py" scripts/audit-flags.py
step "audit-shell-vars.py" python3 scripts/audit-shell-vars.py scripts
# static, instant, and it runs NO gate: whether the gates themselves can hang
# the caller or leak a process is exactly what cannot be answered by running
# them (decision 102)
step "audit-gate-hygiene.py" python3 scripts/audit-gate-hygiene.py
# the suite's own mechanisms are checked the same way: deleting the watchdog,
# the detached launch or the watcher would silently return the repository to a
# state where a gate run can take its caller down (AGENT.md rule 1)
step "audit-gate-hygiene.py --suite" python3 scripts/audit-gate-hygiene.py --suite .
step "audit-verbs.py" scripts/audit-verbs.py
step "no gate routes data through the stdin device" bash -c '
  # COMMENT LINES ARE NOT USAGES. The first version of this guard matched the
  # explanation in e2e-p7-partitions.sh and failed on its own documentation —
  # a guard that trips over its own reason is a guard people delete reasons to
  # satisfy. So: match the path anywhere, ignore matches on comment lines.
  hits=$(grep -n "/dev/stdin" scripts/e2e-*.sh 2>/dev/null |
    grep -vE "^[^:]+:[0-9]+:[[:space:]]*#")
  if [ -n "$hits" ]; then
    echo "$hits"
    echo "these gates route data through the stdin device; write it to a file:" >&2
    echo "bash materialises heredocs/here-strings as pipes on Linux, and a" >&2
    echo "sized-then-pread reader fails on a pipe (see scripts/gates.sh)." >&2
    exit 1
  fi'

step "generated artifacts are current" bash -c '
  python3 tools/gen_spec_corpus.py --check &&
  python3 tools/gen_protocol_vectors.py --check &&
  python3 tools/gen_operator_golden.py --check'

# interfaces must be regenerated with the code that changed them: a
# stale pkg.generated.mbti is how P15 shipped a whole round without
# filing its new public surface (caught in review, not by this gate —
# which is why this step exists).
#
# moon info failing is NOT "no interfaces changed": on CI's first run a
# broken dependency graph (a fresh checkout without `moon update`) made
# this step report PASS while every other moon command failed. Same hole
# as the build matrix below — a tool that could not run is not a tool
# that found nothing.
step "moon info: interfaces are current" bash -c '
  if ! out=$(moon info 2>&1); then
    echo "moon info failed — the interface freshness check could not run:" >&2
    printf "%s\n" "$out" >&2
    exit 1
  fi
  stale=$(git status --porcelain -- "*pkg.generated.mbti")
  if [ -n "$stale" ]; then
    echo "pkg.generated.mbti is stale — run moon info and commit the diff:" >&2
    echo "$stale" >&2
    exit 1
  fi'

for target in wasm wasm-gc js native; do
  # A missing toolchain must not read as a passing build. Matching the
  # output for '^Error' alone silently passed whenever moon failed some
  # other way (no PATH entry, bad flag, killed by the OS) — the compile
  # matrix is the one leg whose whole job is "did this backend build",
  # so the exit status is the answer and the output is printed, not
  # swallowed.
  step "moon build --target $target" bash -c "
    if ! out=\$(moon build --target $target 2>&1); then
      printf '%s\n' \"\$out\" >&2
      exit 1
    fi
    printf '%s\n' \"\$out\" | grep -E '^Error' && exit 1
    exit 0"
done

# 2. tests: the kernel must pass on at least two backends (AGENTS §6)
step "moon test --target native" moon test --target native
step "moon test --target wasm-gc" moon test --target wasm-gc

# The console's kernel (apps/editor-kernel) is the page's ONLY protocol speaker
# and parser (P4), and it runs on the JS target - which this suite was not
# testing at all. The target the page actually runs on was the one target nobody
# tested; the management UI's new verbs are gated by exactly these tests.
step "moon test --target js apps/editor-kernel" moon test --target js apps/editor-kernel

# 3. operator artifacts + ABI surface
step "build-operators.sh" scripts/build-operators.sh

# The E2E gates below must test *this* build. They default to the debug
# binary for the same reason, and exporting it here makes that explicit
# rather than incidental.
export MOONFLUX_EXE="$ROOT/_build/native/debug/build/apps/cli/cli.exe"

# 4. gates
#
# Not in this list: scripts/e2e-p4-editor.sh and
# scripts/e2e-p27-editor-functions.sh. Their first halves are
# mechanical (build, start the broker, assert on data), but the
# milestone's gate is "a browser composes a pipeline and consumes
# data" (and, for p27, "a browser authors a rule asset and rebinds
# it"), and no shell script can press a button. Run them as:
#   scripts/e2e-p4-editor.sh setup    # prints the editor URL
#   … drive the page (agent or human) …
#   scripts/e2e-p4-editor.sh verify
# and, for the function-set UI (two drive rounds, one per revision):
#   scripts/e2e-p27-editor-functions.sh setup
#   … drive round 1 …  bump … drive round 2 …
#   scripts/e2e-p27-editor-functions.sh verify
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
  step "e2e-p22-serve-groups.sh" scripts/e2e-p22-serve-groups.sh
  step "e2e-p23-cli.sh" scripts/e2e-p23-cli.sh
  step "e2e-p24-rotation.sh" scripts/e2e-p24-rotation.sh
  step "e2e-p25-compression.sh" scripts/e2e-p25-compression.sh
  step "e2e-p26-scalar.sh" scripts/e2e-p26-scalar.sh
  step "e2e-p28-maintenance.sh" scripts/e2e-p28-maintenance.sh
  step "e2e-p29-examples.sh" scripts/e2e-p29-examples.sh
  step "e2e-p30-connector-examples.sh" scripts/e2e-p30-connector-examples.sh
  step "e2e-p31-state.sh" scripts/e2e-p31-state.sh
  step "e2e-p32-callout.sh" scripts/e2e-p32-callout.sh
  step "e2e-p33-topic-relay.sh" scripts/e2e-p33-topic-relay.sh
  step "e2e-p34-sc-ha.sh" scripts/e2e-p34-sc-ha.sh
  step "e2e-p35-metrics.sh" scripts/e2e-p35-metrics.sh
  step "e2e-p36-state-migration.sh" scripts/e2e-p36-state-migration.sh
  step "e2e-p37-multi-task.sh" scripts/e2e-p37-multi-task.sh
  step "e2e-p37b-cluster-tasks.sh" scripts/e2e-p37b-cluster-tasks.sh
  step "e2e-p38-run-registration.sh" scripts/e2e-p38-run-registration.sh
  step "e2e-p39-console.sh" scripts/e2e-p39-console.sh
  step "e2e-p40-panels.sh" scripts/e2e-p40-panels.sh
  # the management panel (P37-5c): the scheduler's table and the lifecycle verbs,
  # driven through the page's own kernel artifact against a real control plane
  step "e2e-p53-management-panel.sh" scripts/e2e-p53-management-panel.sh
  # the deployment plane (P0-2): one runner over a whole task set, and the
  # restart that must not repeat a side effect
  step "e2e-p54-deployment-plane.sh" scripts/e2e-p54-deployment-plane.sh
  # a task that cannot stay up must be a FACT in the table, not a log line
  step "e2e-p55-crash-loop.sh" scripts/e2e-p55-crash-loop.sh
  # one template plus a fleet of points becomes a task set, with the refusals that
  # keep a typo out of the cluster
  step "e2e-p56-points.sh" scripts/e2e-p56-points.sh
  # the run log lives in the cluster: task logs --remote reads it from the data
  # node that hosts it, even after the task's own node is gone
  step "e2e-p57-cluster-runlog.sh" scripts/e2e-p57-cluster-runlog.sh
  step "e2e-p41-deploy.sh" scripts/e2e-p41-deploy.sh
  step "e2e-p42-docker.sh" scripts/e2e-p42-docker.sh
  step "e2e-p43-stuck.sh" scripts/e2e-p43-stuck.sh
  step "e2e-p44-http-headers.sh" scripts/e2e-p44-http-headers.sh
  step "e2e-p45-http-tls.sh" scripts/e2e-p45-http-tls.sh
step "e2e-p46-deploy-routing.sh" scripts/e2e-p46-deploy-routing.sh
step "e2e-p47-poll-retry.sh" scripts/e2e-p47-poll-retry.sh
step "e2e-p48-runner.sh" scripts/e2e-p48-runner.sh
step "e2e-p49-docker-cluster.sh" scripts/e2e-p49-docker-cluster.sh
step "e2e-p50-scheduling.sh" scripts/e2e-p50-scheduling.sh
step "e2e-p51-lifecycle.sh" scripts/e2e-p51-lifecycle.sh
step "e2e-p52-control-reconcile.sh" scripts/e2e-p52-control-reconcile.sh
  step "audit-sdf-coverage.sh --selftest" scripts/audit-sdf-coverage.sh --selftest
fi
step "crosscheck-operators.sh" scripts/crosscheck-operators.sh

printf '\n================ summary ================\n'
# Only the failures are re-listed: each passed step already printed its own line
# above, and repeating 70+ labels here was a third of the console output this
# suite used to produce.
if [ "${#FAILED[@]}" -gt 0 ]; then
  for label in "${FAILED[@]}"; do printf 'FAIL  %s\n' "$label"; done
fi
printf '%d passed, %d failed' "${#PASSED[@]}" "${#FAILED[@]}"
if [ "$VERBOSE" != "1" ]; then
  printf '  (per-step logs: %s)' "$LOGDIR"
fi
printf '\n'
[ "${#FAILED[@]}" -eq 0 ] || exit 1
