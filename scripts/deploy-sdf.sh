#!/bin/bash
# deploy-sdf.sh — deploy the SDF example catalog (examples/sdf) natively.
#
# WHAT THIS IS FOR
#
# The example gate (e2e-p29-examples.sh) proves the cases byte-for-byte inside a
# temporary directory. This script is the other half: it lays the catalog out as
# a DEPLOYMENT — a root directory with per-case data dirs, captured logs, a
# recorded process list, and a shared run-registry broker — so an operator can
# start it, look at it, read the logs, and stop it.
#
# THE SHAPE, AND WHY IT IS NOT "one cluster, many tasks"
#
# A case is not a task: a case OWNS ITS TOPIC SPACE, and the catalog has real
# collisions if you flatten it. `sentence` appears in 15-word-counter and again
# in 24-openai-callout; 06-merge, 17-bank, 19-car, 22-http-callout and 24 each
# have several specs that deliberately share a topic (fan-in, or several
# consumers of one stream). P37's rule — a data topic belongs to exactly one
# task, because the read path picks the chain by topic — therefore REFUSES a
# flattened deploy, correctly.
#
# So each case is deployed into its own data dir (its own topic space), and the
# broker is a RUN REGISTRY: every run reports to it (P37-2), which is what makes
# `status`, the console's runs panel, and /metrics able to see the whole
# deployment at once. The runs do not share storage, and they do not need to.
#
# WHAT RUNS AUTOMATICALLY
#
# Only cases with ONE spec whose source is `file` or `stdin` are run by `start`:
# the other cases are multi-stage (their stages must run in an order the catalog
# documents per case, not a rule this script can guess), or need an external
# system (http/mqtt/kafka). Those are listed as `deploy-only` WITH THEIR REASON
# in catalog.tsv — never silently skipped.
#
# USAGE
#
#   deploy-sdf.sh start|status|verify|logs [case]|stop|list
#
#   MOONFLUX_DEPLOY_DIR   deployment root (default: ./_deploy)
#   MOONFLUX_EXE          the CLI to deploy (default: the debug build)
#   MOONFLUX_DEPLOY_PORT  the registry broker's port (default 19801)
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

EXE="${MOONFLUX_EXE:-$ROOT/_build/native/debug/build/apps/cli/cli.exe}"
DEPLOY="${MOONFLUX_DEPLOY_DIR:-$ROOT/_deploy}"
PORT="${MOONFLUX_DEPLOY_PORT:-19801}"
METRICS_PORT="${MOONFLUX_DEPLOY_METRICS_PORT:-19802}"
EXAMPLES="$ROOT/examples/sdf"
REGISTRY="127.0.0.1:$PORT"

die() { echo "deploy-sdf: $*" >&2; exit 1; }
note() { echo "deploy-sdf: $*"; }

# ---------------------------------------------------------------------
# the catalog: one row per case, with the mode and (for deploy-only) why

catalog() { # writes catalog.tsv: case <tab> mode <tab> spec <tab> reason
  python3 - "$EXAMPLES" > "$DEPLOY/catalog.tsv" <<'PY'
import json, pathlib, sys
examples = pathlib.Path(sys.argv[1])
for case in sorted(p for p in examples.iterdir() if p.is_dir()):
    specs = sorted(case.glob('spec*.json'))
    if not specs:
        print(f"{case.name}\tdeploy-only\t-\tno spec file in the catalog directory")
        continue
    kinds = []
    for spec in specs:
        kinds.append(json.loads(spec.read_text())["spec"]["source"]["type"])
    external = sorted({k for k in kinds if k in ("http", "mqtt", "kafka")})
    if external:
        print(f"{case.name}\tdeploy-only\t-\tsource needs an external system: {', '.join(external)}")
        continue
    if len(specs) > 1:
        print(f"{case.name}\tdeploy-only\t-\t{len(specs)} stages: their order is documented per case, not guessable here")
        continue
    if kinds[0] not in ("file", "stdin"):
        print(f"{case.name}\tdeploy-only\t-\tsource kind {kinds[0]} is not runnable unattended")
        continue
    # A case can carry several expected files on purpose (08 has the raw view,
    # the service view and two compaction snapshots; 20/21 have stream and
    # state). Running it is still useful; VERIFYING it needs one golden, and
    # picking one of several here would be this script inventing the case's
    # meaning. So: run it, and say why it is not verified.
    goldens = sorted(case.glob('expected*.txt'))
    spec_name = specs[0].name
    if [g.name for g in goldens] == ["expected.txt"]:
        print(f"{case.name}\trun\t{spec_name}\t-")
    elif goldens:
        names = ", ".join(g.name for g in goldens)
        print(f"{case.name}\trun-unverified\t{spec_name}\t{len(goldens)} views to compare ({names}): the case's README says which")
    else:
        print(f"{case.name}\trun-unverified\t{spec_name}\tno expected file to verify against")
PY
}

runs_in_catalog() { awk -F'\t' '$2 == "run" || $2 == "run-unverified" {print $1}' "$DEPLOY/catalog.tsv"; }
verified_in_catalog() { awk -F'\t' '$2 == "run" {print $1}' "$DEPLOY/catalog.tsv"; }
spec_of() { awk -F'\t' -v c="$1" '$1 == c {print $3}' "$DEPLOY/catalog.tsv"; }

port_free() { ! lsof -i ":$1" -sTCP:LISTEN > /dev/null 2>&1; }

wait_listen() { local port="$1" tenths="${2:-100}" i=0
  while [ "$i" -lt "$tenths" ]; do
    lsof -i ":$port" -sTCP:LISTEN > /dev/null 2>&1 && return 0
    sleep 0.1; i=$((i + 1))
  done
  return 1
}

# ---------------------------------------------------------------------
preflight() {
  [ -x "$EXE" ] || die "no CLI at $EXE (build it: moon build --target native, then scripts/build-operators.sh)"
  # Every module a spec references must exist BEFORE anything starts: a wasm
  # path that is not there fails at apply time, one case at a time, which is a
  # slow way to learn that the deployment was never complete.
  local missing=0
  while read -r module; do
    [ -z "$module" ] && continue
    case "$module" in
    /*) [ -f "$module" ] || { note "missing operator module $module"; missing=1; } ;;
    *) [ -f "$ROOT/$module" ] || { note "missing operator module $ROOT/$module"; missing=1; } ;;
    esac
  done < <(python3 - "$EXAMPLES" <<'PY'
import json, pathlib, sys
for spec in pathlib.Path(sys.argv[1]).glob('*/spec*.json'):
    for t in json.loads(spec.read_text())["spec"].get("transforms", []):
        if t.get("type") == "wasm":
            print(t.get("module", ""))
PY
)
  [ "$missing" = "0" ] || die "the catalog references operator modules that are not built (run scripts/build-operators.sh)"
}

start_broker() {
  mkdir -p "$DEPLOY/broker"
  "$EXE" serve --data-dir "$DEPLOY/broker" --listen "127.0.0.1:$PORT" \
    --metrics-listen "127.0.0.1:$METRICS_PORT" > "$DEPLOY/broker/serve.log" 2>&1 &
  echo $! > "$DEPLOY/broker/broker.pid"
  wait_listen "$PORT" || { cat "$DEPLOY/broker/serve.log"; die "the registry broker did not start"; }
  note "registry broker up on $REGISTRY (metrics 127.0.0.1:$METRICS_PORT)"
}

start_case() { # $1 = case
  local case="$1" dir="$DEPLOY/cases/$1" spec
  spec="$EXAMPLES/$1/$(spec_of "$1")"
  [ -f "$spec" ] || die "$1: the catalog names $spec, which is not there"
  mkdir -p "$dir"
  if [ -f "$EXAMPLES/$1/fns.json" ]; then
    "$EXE" function-set create --file "$EXAMPLES/$1/fns.json" --data-dir "$dir" \
      > "$DEPLOY/logs/$1.fns" 2>&1 ||
      { cat "$DEPLOY/logs/$1.fns"; die "$1: function-set create failed"; }
  fi
  # deployed, not ad-hoc: the case's own data dir holds the applied task, so
  # `pipeline list --data-dir` shows it and a restart could run it without the
  # original spec file
  "$EXE" pipeline apply --data-dir "$dir" -f "$spec" > "$DEPLOY/logs/$1.apply" 2>&1 ||
    { cat "$DEPLOY/logs/$1.apply"; die "$1: apply failed"; }
  # ...and it reports to the shared registry, while its records stay in its own
  # data dir (that is what makes the deployment watchable as one thing)
  "$EXE" pipeline run --data-dir "$dir" --control "$REGISTRY" \
    > "$DEPLOY/logs/$1.out" 2> "$DEPLOY/logs/$1.err" &
  echo "$1:$!" >> "$DEPLOY/run/pids"
}

wait_for_runs() { # tenths; waits until every auto-run case's process is gone
  local tenths="${1:-300}" i=0 alive=1
  while [ "$i" -lt "$tenths" ]; do
    alive=0
    while IFS=: read -r case pid; do
      kill -0 "$pid" 2>/dev/null && alive=1
    done < "$DEPLOY/run/pids"
    [ "$alive" = "0" ] && return 0
    sleep 0.1; i=$((i + 1))
  done
  return 1
}

cmd_start() {
  [ -f "$DEPLOY/catalog.tsv" ] && grep -q . "$DEPLOY/catalog.tsv" && die "$DEPLOY is already deployed (run stop first)"
  rm -rf "$DEPLOY"
  mkdir -p "$DEPLOY/logs" "$DEPLOY/run" "$DEPLOY/cases"
  preflight
  catalog
  local total run_only verified unverified
  total=$(wc -l < "$DEPLOY/catalog.tsv" | tr -d ' ')
  run_only=$(runs_in_catalog | wc -l | tr -d ' ')
  verified=$(verified_in_catalog | wc -l | tr -d ' ')
  unverified=$((run_only - verified))
  note "$total case(s): $run_only run ($verified verifiable, $unverified without a single golden), $((total - run_only)) deploy-only"
  start_broker
  : > "$DEPLOY/run/pids"
  while read -r case; do
    start_case "$case"
  done < <(runs_in_catalog)
  if wait_for_runs 600; then
    note "all $run_only auto-run case(s) finished"
  else
    note "warning: some runs are still going after 60s (see $DEPLOY/logs)"
  fi
  note "deployed to $DEPLOY — now: deploy-sdf.sh status | verify | logs <case> | stop"
}

# ---------------------------------------------------------------------
cmd_status() {
  [ -f "$DEPLOY/catalog.tsv" ] || die "nothing deployed under $DEPLOY"
  local broker_state="down" pid
  if [ -f "$DEPLOY/broker/broker.pid" ] && kill -0 "$(cat "$DEPLOY/broker/broker.pid")" 2>/dev/null; then
    broker_state="up"
  fi
  echo "deployment:  $DEPLOY (registry $REGISTRY: $broker_state)"
  echo
  echo "runs (from the registry, P37-2):"
  "$EXE" run list --remote "$REGISTRY" 2>/dev/null | sed 's/^/  /' || echo "  (the registry did not answer)"
  echo
  echo "catalog:"
  while IFS=$'\t' read -r case mode spec reason; do
    if [ "$mode" = "run" ]; then
      local out="$DEPLOY/logs/$case.out"
      local verdict="verified"
      if [ ! -s "$out" ]; then
        verdict="no output"
      elif ! cmp -s "$out" "$EXAMPLES/$case/expected.txt"; then
        verdict="DIFFERS from expected.txt"
      fi
      printf '  %-26s %-14s %s\n' "$case" "$mode" "$verdict"
    elif [ "$mode" = "run-unverified" ]; then
      # it ran; there is simply no single golden to compare against, and the
      # reason names the files that are there instead of picking one
      local ran="ran, not verified"
      [ -s "$DEPLOY/logs/$case.out" ] || ran="no output"
      printf '  %-26s %-14s %s — %s\n' "$case" "$mode" "$ran" "$reason"
    else
      printf '  %-26s %-14s %s\n' "$case" "deploy-only" "$reason"
    fi
  done < "$DEPLOY/catalog.tsv"
}

cmd_verify() {
  [ -f "$DEPLOY/catalog.tsv" ] || die "nothing deployed under $DEPLOY"
  local failed=0 checked=0
  while read -r case; do
    checked=$((checked + 1))
    local out="$DEPLOY/logs/$case.out" want="$EXAMPLES/$case/expected.txt"
    [ -f "$out" ] || { echo "deploy-sdf: $case produced no output" >&2; failed=1; continue; }
    if ! cmp -s "$out" "$want"; then
      echo "deploy-sdf: $case differs from $want" >&2
      diff -u "$want" "$out" | head -12 >&2
      failed=1
    fi
  done < <(verified_in_catalog)
  [ "$failed" = "0" ] || die "$checked case(s) checked, at least one differs"
  note "$checked case(s) verified byte-for-byte against their expected.txt"
}

cmd_list() {
  [ -f "$DEPLOY/catalog.tsv" ] || die "nothing deployed under $DEPLOY (run start)"
  cat "$DEPLOY/catalog.tsv"
}

cmd_logs() {
  local case="${1:-}"
  [ -f "$DEPLOY/catalog.tsv" ] || die "nothing deployed under $DEPLOY"
  if [ -z "$case" ]; then
    cat "$DEPLOY/catalog.tsv"
    return 0
  fi
  [ -d "$DEPLOY/cases/$case" ] || die "no deployed case named $case"
  echo "--- $case stderr (diagnostics) ---"
  cat "$DEPLOY/logs/$case.err" 2>/dev/null || true
  echo "--- $case stdout (the sink's data) ---"
  cat "$DEPLOY/logs/$case.out" 2>/dev/null || true
  local topic
  topic=$(python3 - "$EXAMPLES/$case/$(spec_of "$case")" <<'PY'
import json, sys
print(json.load(open(sys.argv[1]))["metadata"]["name"] + ".run-log")
PY
)
  if "$EXE" consume --topic "$topic" --from 0 --data-dir "$DEPLOY/cases/$case" \
    > "$DEPLOY/logs/$case.runlog" 2>/dev/null; then
    echo "--- run log ($topic: the run's own record, P37-2) ---"
    cat "$DEPLOY/logs/$case.runlog"
  else
    echo "--- no run log ($topic): the run was not pointed at the registry ---"
  fi
}

cmd_stop() {
  [ -d "$DEPLOY" ] || die "nothing deployed under $DEPLOY"
  local killed=0
  if [ -f "$DEPLOY/run/pids" ]; then
    while IFS=: read -r case pid; do
      if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null
        killed=$((killed + 1))
      fi
    done < "$DEPLOY/run/pids"
    # a streaming run that ignores TERM is killed; a run that ignores both is a
    # bug worth seeing, so the escalation is bounded and reported
    sleep 1
    while IFS=: read -r case pid; do
      kill -9 "$pid" 2>/dev/null || true
    done < "$DEPLOY/run/pids"
  fi
  if [ -f "$DEPLOY/broker/broker.pid" ]; then
    kill "$(cat "$DEPLOY/broker/broker.pid")" 2>/dev/null && killed=$((killed + 1))
    sleep 1
    kill -9 "$(cat "$DEPLOY/broker/broker.pid")" 2>/dev/null || true
  fi
  note "stopped $killed process(es); the deployment root is kept ($DEPLOY) so the logs remain readable"
}

case "${1:-}" in
start) cmd_start ;;
status) cmd_status ;;
verify) cmd_verify ;;
logs) shift; cmd_logs "${1:-}" ;;
list) cmd_list ;;
stop) cmd_stop ;;
*) die "usage: deploy-sdf.sh start|status|verify|logs [case]|list|stop" ;;
esac
