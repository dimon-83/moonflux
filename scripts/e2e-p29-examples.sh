#!/bin/bash
# E2E-P29: the SDF example ports (examples/sdf/*), run end to end.
#
# These are not unit fixtures: every case is a *documented application*
# in examples/sdf/, and this gate proves the document's claim — run the
# case the way its README says, compare the bytes with the frozen
# expected file. Eight legs, each tied to the stateful-dataflow-examples
# directory it was ported from (see docs/sdf-examples-port.md):
#
#   1  map        mask every digit in a JSON ssn      (primitives/map,
#                dataflows/mask-user-pii, packages/mask-ssn)
#   2  filter     keep the question                   (primitives/filter)
#   3  filter-map drop short, uppercase long          (primitives/filter-map)
#   4  flat-map   sentence -> words                   (primitives/flat-map,
#                dataflows/split-sentence)
#   5  split      one source, two filtered streams    (primitives/split/filter)
#   6  merge      two sources, one topic              (primitives/merge)
#   7  keys       keys ride the log                   (primitives/key-value/*)
#   8  state      the log IS the state: raw log vs the applied
#                topology's view, and keyed compaction as "latest per
#                key" with offsets preserved        (primitives/update-state,
#                dataflows/word-counter)
#
# What this gate deliberately does NOT assert: any SDF behaviour that has
# no moonflux equivalent (durable keyed state inside a service, windows
# and watermarks, the SQL engine, arrow-row state). Those are recorded as
# gaps in docs/sdf-examples-port.md instead of being faked here.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
EXE="${MOONFLUX_EXE:-$ROOT/_build/native/debug/build/apps/cli/cli.exe}"
EXAMPLES="$ROOT/examples/sdf"
WORK="$(mktemp -d /tmp/moonflux-p29-examples.XXXXXX)"
PORT="${MOONFLUX_P29_PORT:-19901}"
PIDS=()

cleanup() {
  for pid in "${PIDS[@]:-}"; do kill "$pid" 2>/dev/null || true; done
  # ports are the fallback: a child that was restarted by a command
  # substitution is adopted by init and no longer reachable by pid
  pkill -f "moonflux-p29-examples" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

fail() { echo "E2E-P29-EXAMPLES FAIL: $*" >&2; exit 1; }
pass() { echo "E2E-P29-EXAMPLES PASS: $*"; }

wait_listen() { # $1 = port
  for _ in $(seq 1 60); do
    # shellcheck disable=SC2009
    lsof -i ":$1" -sTCP:LISTEN > /dev/null 2>&1 && return 0
    sleep 0.1
  done
  return 1
}

# Compares a produced file with a frozen expectation, and says which case
# broke — a diff without a name is a diff nobody wants to read.
check() { # $1 = label, $2 = actual file, $3 = expected file
  if ! diff -u "$3" "$2" > "$WORK/diff.txt" 2>&1; then
    echo "--- expected vs actual ($1) ---" >&2
    cat "$WORK/diff.txt" >&2
    fail "$1: output does not match $3"
  fi
}

[ -x "$EXE" ] || fail "cli binary not found at $EXE (run: moon build --target native)"
for op in operator-filter operator-flatmap; do
  [ -f "$ROOT/_build/wasm/debug/build/apps/$op/$op.wasm" ] ||
    fail "missing $op.wasm — run: scripts/build-operators.sh"
done

start_serve() { # $1 = data dir, $2 = port
  "$EXE" serve --data-dir "$1" --listen "127.0.0.1:$2" > "$WORK/serve.log" 2>&1 &
  SERVE_PID="$!"
  PIDS+=("$SERVE_PID")
  wait_listen "$2" || { cat "$WORK/serve.log"; fail "serve did not start on $2"; }
}

# ---- 1. map: mask the digits of an ssn (a function-set asset) -----------
# The port's one wrinkle: function sets are deployed to a *node*, and the
# CLI has no local (--data-dir) creation verb, so a serve is started once
# to install the asset into the same data dir the local run then uses.
D="$WORK/d01"
start_serve "$D" "$PORT"
"$EXE" function-set create --remote "127.0.0.1:$PORT" --file "$EXAMPLES/01-map-mask-ssn/fns.json" \
  > "$WORK/fns-deploy.txt" 2>&1 || { cat "$WORK/fns-deploy.txt"; fail "the pii function set was refused"; }
grep -q "revision 1" "$WORK/fns-deploy.txt" || fail "the asset deploy did not report a revision"
# the serve has done its one job (installing the asset into this data
# dir); the run below is local, so the port can go. (No ${PIDS[-1]}:
# macOS ships bash 3.2, where a negative subscript is a syntax error.)
kill "$SERVE_PID" 2>/dev/null || true
sleep 0.2
"$EXE" pipeline apply --data-dir "$D" --file "$EXAMPLES/01-map-mask-ssn/spec.json" > /dev/null \
  || fail "case 1: apply failed (is the function set in this data dir?)"
"$EXE" pipeline run --data-dir "$D" > "$WORK/01.out" 2> "$WORK/01.err" \
  || { cat "$WORK/01.err"; fail "case 1: pipeline run failed"; }
check "1 map/mask-ssn" "$WORK/01.out" "$EXAMPLES/01-map-mask-ssn/expected.txt"
pass "1. map: mask_ssn() from the pii function set masked every digit (revision 1)"

# ---- 2. filter: keep the question ---------------------------------------
"$EXE" pipeline run --data-dir "$WORK/d02" --spec "$EXAMPLES/02-filter-questions/spec.json" \
  > "$WORK/02.out" 2> "$WORK/02.err" || { cat "$WORK/02.err"; fail "case 2: run failed"; }
check "2 filter" "$WORK/02.out" "$EXAMPLES/02-filter-questions/expected.txt"
pass "2. filter: the wasm operator dropped the non-questions (1 -> 0)"

# ---- 3. filter-map: drop short, uppercase long --------------------------
"$EXE" pipeline run --data-dir "$WORK/d03" --spec "$EXAMPLES/03-filter-map-uppercase/spec.json" \
  > "$WORK/03.out" 2> "$WORK/03.err" || { cat "$WORK/03.err"; fail "case 3: run failed"; }
check "3 filter-map" "$WORK/03.out" "$EXAMPLES/03-filter-map-uppercase/expected.txt"
pass "3. filter-map: wasm filter (min_len 11) then the mbel upper() rule — a chain across both engines"

# ---- 4. flat-map: sentence -> words ------------------------------------
"$EXE" pipeline run --data-dir "$WORK/d04" --spec "$EXAMPLES/04-flat-map-words/spec.json" \
  > "$WORK/04.out" 2> "$WORK/04.err" || { cat "$WORK/04.err"; fail "case 4: run failed"; }
check "4 flat-map" "$WORK/04.out" "$EXAMPLES/04-flat-map-words/expected.txt"
pass "4. flat-map: one sentence became four records (1 -> N)"

# ---- 5. split: one source, two filtered streams ------------------------
# SDF expresses this inside one service with sink-scoped transforms; a
# moonflux spec has exactly one sink, so the split is two ingress specs
# over the same source — recorded as a topological difference, not hidden.
"$EXE" pipeline run --data-dir "$WORK/d05e" --spec "$EXAMPLES/05-split-two-streams/spec-errors.json" \
  > "$WORK/05-errors.out" 2> "$WORK/05e.err" || { cat "$WORK/05e.err"; fail "case 5: errors branch failed"; }
"$EXE" pipeline run --data-dir "$WORK/d05w" --spec "$EXAMPLES/05-split-two-streams/spec-warns.json" \
  > "$WORK/05-warns.out" 2> "$WORK/05w.err" || { cat "$WORK/05w.err"; fail "case 5: warns branch failed"; }
check "5 split (errors)" "$WORK/05-errors.out" "$EXAMPLES/05-split-two-streams/expected-errors.txt"
check "5 split (warns)" "$WORK/05-warns.out" "$EXAMPLES/05-split-two-streams/expected-warns.txt"
pass "5. split: the two branches partition the input (2 ERROR lines, 1 WARN line, no overlap)"

# ---- 6. merge: two sources, one topic ----------------------------------
# SDF merges inside a service (two sources + per-source maps into one
# sink). moonflux merges at the *topic*: two ingress pipelines naming the
# same topic, and the log is then the merged stream, in append order.
D="$WORK/d06"
"$EXE" pipeline run --data-dir "$D" --spec "$EXAMPLES/06-merge-two-sources/spec-a.json" \
  > "$WORK/06a.out" 2> "$WORK/06a.err" || { cat "$WORK/06a.err"; fail "case 6: source a failed"; }
"$EXE" pipeline run --data-dir "$D" --spec "$EXAMPLES/06-merge-two-sources/spec-b.json" \
  > "$WORK/06b.out" 2> "$WORK/06b.err" || { cat "$WORK/06b.err"; fail "case 6: source b failed"; }
"$EXE" consume --topic sdf-06-licenses --from 0 --data-dir "$D" 2> "$WORK/06.err" \
  | cut -f1,4 > "$WORK/06-merged.out" || { cat "$WORK/06.err"; fail "case 6: consume failed"; }
check "6 merge" "$WORK/06-merged.out" "$EXAMPLES/06-merge-two-sources/expected-merged.txt"
pass "6. merge: both producers landed in one topic, offsets 0..3 in append order"

# ---- 7. keys ride the log ----------------------------------------------
# SDF's key/value primitives carry a key beside the value through every
# hop. moonflux's log has the same shape: the key is a first-class column
# that survives storage and is visible on the way out.
D="$WORK/d07"
"$EXE" produce --topic kv --file "$EXAMPLES/07-key-value-keys/users.txt" --key-separator '>' \
  --data-dir "$D" > /dev/null 2> "$WORK/07p.err" || { cat "$WORK/07p.err"; fail "case 7: produce failed"; }
"$EXE" consume --topic kv --from 0 --data-dir "$D" 2> "$WORK/07.err" \
  | cut -f3,4 > "$WORK/07.out" || { cat "$WORK/07.err"; fail "case 7: consume failed"; }
check "7 keys" "$WORK/07.out" "$EXAMPLES/07-key-value-keys/expected-keys-values.txt"
pass "7. keys: the key is stored with the record and survives the round trip"

# ---- 8. state: raw log vs the applied topology's view, then compaction --
# (b) is prepared FIRST, on purpose: the keyed records are written before
#     any server opens this log, because the log belongs to one writer
#     (P16) — and because compaction only touches SEALED segments, and
#     one `produce` is one append. So they are produced one at a time
#     with a small roll threshold; without that the whole input is a
#     single active segment and compaction correctly reports 0 segments.
D="$WORK/d08"
while read -r line; do
  printf '%s\n' "$line" > "$WORK/one.txt"
  MOONFLUX_ROLL_BYTES=20 "$EXE" produce --topic state --file "$WORK/one.txt" --key-separator '=' \
    --data-dir "$D" > /dev/null 2>&1 || fail "case 8: keyed produce failed"
done < "$EXAMPLES/08-state-is-the-log/updates.txt"
"$EXE" consume --topic state --from 0 --data-dir "$D" 2> "$WORK/08b.err" \
  | cut -f1,3,4 > "$WORK/08-before.out" || { cat "$WORK/08b.err"; fail "case 8: consume failed"; }
check "8 compaction (before)" "$WORK/08-before.out" "$EXAMPLES/08-state-is-the-log/expected-compact-before.txt"

# (a) the service view. SDF's `sources: topic` services read a topic and
#     transform on the way out; moonflux's equivalent is a server with an
#     applied topology: the client's fetch is transformed, while the log
#     still holds what the producer wrote. Two views of one topic.
"$EXE" pipeline apply --data-dir "$D" --file "$EXAMPLES/08-state-is-the-log/spec.json" > /dev/null \
  || fail "case 8: apply failed"
start_serve "$D" "$PORT"
"$EXE" produce --remote "127.0.0.1:$PORT" --topic sdf-08-sentences \
  --file "$EXAMPLES/08-state-is-the-log/input.txt" > /dev/null 2> "$WORK/08p.err" \
  || { cat "$WORK/08p.err"; fail "case 8: remote produce failed"; }
"$EXE" consume --remote "127.0.0.1:$PORT" --topic sdf-08-sentences --from 0 2> "$WORK/08s.err" \
  | cut -f4 > "$WORK/08-service.out" || { cat "$WORK/08s.err"; fail "case 8: remote consume failed"; }
check "8 service view" "$WORK/08-service.out" "$EXAMPLES/08-state-is-the-log/expected-service.txt"
"$EXE" consume --topic sdf-08-sentences --from 0 --data-dir "$D" 2> "$WORK/08r.err" \
  | cut -f4 > "$WORK/08-raw.out" || { cat "$WORK/08r.err"; fail "case 8: local consume failed"; }
check "8 raw log view" "$WORK/08-raw.out" "$EXAMPLES/08-state-is-the-log/expected-raw.txt"
pass "8a. the applied topology transformed the fetch (words) while the log kept the sentences"

# (b) the compaction itself, through the server that owns the log
MOONFLUX_ROLL_BYTES=20 "$EXE" cluster compact --remote "127.0.0.1:$PORT" --topic state \
  > "$WORK/08-compact.txt" 2>&1 || { cat "$WORK/08-compact.txt"; fail "case 8b: compact failed"; }
grep -q "compacted 1 segment(s)" "$WORK/08-compact.txt" \
  || { cat "$WORK/08-compact.txt"; fail "case 8b: expected exactly one sealed segment to be compacted"; }
grep -q "1 records dropped" "$WORK/08-compact.txt" \
  || { cat "$WORK/08-compact.txt"; fail "case 8b: expected exactly one superseded record to be dropped"; }
# the floor moved: reading below it is a structured refusal, not an empty
# window (the P8 discipline), and the survivors keep their own offsets
"$EXE" consume --topic state --from 0 --data-dir "$D" > "$WORK/08-from0.out" 2> "$WORK/08-from0.err"
[ -s "$WORK/08-from0.out" ] && fail "case 8b: a read below the new floor produced records"
grep -q "OffsetOutOfRange" "$WORK/08-from0.err" \
  || { cat "$WORK/08-from0.err"; fail "case 8b: a read below the new floor was not refused by name"; }
"$EXE" consume --topic state --from 1 --data-dir "$D" 2> "$WORK/08c.err" \
  | cut -f1,3,4 > "$WORK/08-after.out" || { cat "$WORK/08c.err"; fail "case 8b: post-compaction consume failed"; }
check "8 compaction (after)" "$WORK/08-after.out" "$EXAMPLES/08-state-is-the-log/expected-compact-after.txt"
pass "8b. compaction kept the latest value per key at its original offsets, and refused a stale read by name"

echo "E2E-P29-EXAMPLES: 8 legs green (8 example applications)"
