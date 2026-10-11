#!/bin/bash
# E2E-P29: the SDF example ports (examples/sdf/*), run end to end.
#
# These are not unit fixtures: every case is a *documented application*
# in examples/sdf/, and this gate proves the document's claim — run the
# case the way its README says, compare the bytes with the frozen
# expected file. Fifteen legs, each tied to the stateful-dataflow-examples
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
#   9  deserialize read a named field out of JSON     (primitives/custom-serialization)
#  10  projection  serialize fields into a new shape,
#                comparing a JSON number as a number
#  11  round trip  toPairs -> fromPairs -> toJSON is
#                the input, byte for byte
#  12  parse-sentence sentence -> words -> lengths    (packages/parse-sentence)
#  13  regex       keep the matching records          (primitives/regex)
#  14  regex invert the same program, opposite set
#  15  regex bound  an unsupported construct is an
#                  apply-time refusal, by name
#  16  word-counter keyed state: the running count per
#                  word, byte for byte
#  18  word-probe   a second pipeline reads the SAME state
#                  topic and answers per word
#  20  bank          per-account balances from the reference
#                  sample events, byte for byte
#  21  bank          the state topic converges to one balance
#                  per account
#  23  unreal        per-label event counts over the reference's
#                  own 183-event sample, byte for byte
#  24  unreal        the label table's catch-all: beginPlay and
#                  endPlay both land in `other`
#  26  car           speeding selection (mph > 60) through the
#                  structural predicate
#  27  car           split by location: two pipelines, disjoint
#                  selections that add up to the speeding set
#  28  car           30-second colour windows: ISO-8601 event
#                  time, one state entry per colour@window
#  30  helsinki      incomplete events are dropped, and the rest
#                  average per vehicle per 5-second window
#  32  ny-transit    average tip per pickup zone per 30-second
#                  window, over TLC-shaped trip records
#  33  ny-transit    the average's state is sum,count, so the
#                  running mean can be checked by hand
#  31  helsinki      the state is sum,count (not a self-referential
#                  average), so the arithmetic can be checked
#  29  car           a registered plate on a different car is a
#                  stolen plate, and the check writes nothing
#  25  unreal        10-second tumbling counts: the same label
#                  in two windows is two state entries
#  22  bank          an overdrawing withdrawal is flagged and
#                  selected into its own stream
#  19  word-probe   the probe writes nothing (state record
#                  count unchanged) and reports `missing`
#                  for a word the state never saw
#  17  word-counter the state topic holds one entry per
#      (state/state) word, and a second run continues
#                  from it (the log is the truth)
#                apply-time refusal, by name
#
# What this gate deliberately does NOT assert: any SDF behaviour that has
# no moonflux equivalent (durable keyed state *inside* a service, windows
# and watermarks, the SQL engine, arrow-row state). Those are recorded as
# gaps in docs/sdf-examples-port.md instead of being faked here — case 8
# shows the honest substitute for the first of them.
# T108 (the publish-time probe) is what makes legs 9-11 publishable at
# all; scripts/e2e-p1-rules.sh holds its rejections.
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
# The asset goes straight into the data dir the run reads, because the
# function-set verbs take --data-dir (P30/T107): installing an asset no
# longer requires starting a server for it.
D="$WORK/d01"
"$EXE" function-set create --file "$EXAMPLES/01-map-mask-ssn/fns.json" --data-dir "$D" \
  > "$WORK/fns-deploy.txt" 2>&1 || { cat "$WORK/fns-deploy.txt"; fail "the pii function set was refused"; }
grep -q "revision 1" "$WORK/fns-deploy.txt" || fail "the asset deploy did not report a revision"
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

# ---- 9-11. JSON fields: deserialize, project, round-trip ----------------
# SDF's custom-serialization primitive reads a line into a typed struct and
# writes one back out. Here the payload stays opaque and the expression
# does the work: get(fromJSON(value), "maker") reads a field,
# toJSON(fromPairs([...])) writes a new shape, and toPairs/fromPairs makes
# the identity round trip — which is the strongest available statement
# that our JSON view is faithful (T108 widened the publish-time probe so
# this could publish at all).
D="$WORK/d12"
"$EXE" pipeline run --data-dir "$D" --spec "$EXAMPLES/12-custom-serialization/spec-deserialize.json" \
  > "$WORK/12a.out" 2> "$WORK/12a.err" || { cat "$WORK/12a.err"; fail "case 12: deserialize run failed"; }
check "12 deserialize (JSON -> field)" "$WORK/12a.out" "$EXAMPLES/12-custom-serialization/expected-deserialize.txt"
"$EXE" pipeline run --data-dir "$D" --spec "$EXAMPLES/12-custom-serialization/spec-projection.json" \
  > "$WORK/12b.out" 2> "$WORK/12b.err" || { cat "$WORK/12b.err"; fail "case 12: projection run failed"; }
check "12 projection (fields -> new JSON)" "$WORK/12b.out" "$EXAMPLES/12-custom-serialization/expected-projection.txt"
pass "9. JSON field read publishes and transforms (get(fromJSON(value), key))"
pass "10. fields serialize back into a new JSON shape, numbers compared as numbers"

"$EXE" pipeline run --data-dir "$D" --spec "$EXAMPLES/12-custom-serialization/spec-roundtrip.json" \
  > "$WORK/12c.out" 2> "$WORK/12c.err" || { cat "$WORK/12c.err"; fail "case 12: round-trip run failed"; }
check "12 round trip (toPairs -> fromPairs -> toJSON)" "$WORK/12c.out" "$EXAMPLES/12-custom-serialization/expected-roundtrip.txt"
pass "11. toJSON(fromPairs(toPairs(fromJSON(value)))) is the input, byte for byte"

# ---- 12. parse-sentence: the package's two functions, end to end --------
"$EXE" pipeline run --data-dir "$WORK/d13" --spec "$EXAMPLES/13-parse-sentence/spec.json" \
  > "$WORK/13.out" 2> "$WORK/13.err" || { cat "$WORK/13.err"; fail "case 13: run failed"; }
check "13 parse-sentence" "$WORK/13.out" "$EXAMPLES/13-parse-sentence/expected.txt"
pass "12. parse-sentence: sentence-to-words (flat-map) then word-length (len), as the package defines them"

# ---- 13-15. regex: the kernel's own engine, as a spec-level filter ----
# SDF's regex primitive is a filter SmartModule using the regex crate; the
# port puts the engine in the kernel (pure computation: no IO, no clock,
# no dependency) and the pattern in the spec. Compilation happens at apply
# time, which is what makes leg 15 possible: an unsupported construct is a
# publish-time refusal, not a per-record surprise.
D="$WORK/d14"
"$EXE" pipeline run --data-dir "$D" --spec "$EXAMPLES/14-regex-genz/spec.json" \
  > "$WORK/14.out" 2> "$WORK/14.err" || { cat "$WORK/14.err"; fail "case 14: regex filter run failed"; }
check "14 regex filter" "$WORK/14.out" "$EXAMPLES/14-regex-genz/expected.txt"
pass "13. regex: the pattern keeps the records whose value matches"

"$EXE" pipeline run --data-dir "$D" --spec "$EXAMPLES/14-regex-genz/spec-invert.json" \
  > "$WORK/14i.out" 2> "$WORK/14i.err" || { cat "$WORK/14i.err"; fail "case 14: inverted run failed"; }
check "14 regex invert" "$WORK/14i.out" "$EXAMPLES/14-regex-genz/expected-invert.txt"
pass "14. regex invert: the same program keeps the records that do not match"

if "$EXE" pipeline apply --data-dir "$WORK/d14bad" \
    --file "$EXAMPLES/14-regex-genz/spec-unsupported.json" > "$WORK/14bad.out" 2>&1; then
  fail "case 14: an unsupported regex construct should be refused at apply"
fi
grep -q "unsupported" "$WORK/14bad.out" ||
  { cat "$WORK/14bad.out"; fail "case 14: the refusal does not name the unsupported construct"; }
pass "15. regex: an unsupported construct (lookahead) is refused at apply, by name"

# ---- 16-17. word-counter: keyed state, per-word counts -----------------
# The stateful case: the words become record keys, and a v3 operator counts
# them per key. Leg 16 is the byte-exact stream; leg 17 is the state topic
# (the durable half) plus a second run, which must continue rather than
# restart. That second run is the whole point of "state lives in a log".
DWC="$WORK/p29-wordcounter"
"$EXE" pipeline run --data-dir "$DWC" --spec "$EXAMPLES/15-word-counter/spec.json" \
  > "$WORK/16.out" 2> "$WORK/16.err" || { cat "$WORK/16.err"; fail "case 16: word-counter run failed"; }
check "16 word-counter counts" "$WORK/16.out" "$EXAMPLES/15-word-counter/expected.txt"
pass "16. word-counter: one running count per word occurrence, byte for byte"

"$EXE" consume --topic word-counts --from 0 --data-dir "$DWC" 2>/dev/null | cut -f3,4 | sort \
  > "$WORK/17.state"
check "17 state topic per word" "$WORK/17.state" "$EXAMPLES/15-word-counter/expected-state.txt"
"$EXE" pipeline run --data-dir "$DWC" --spec "$EXAMPLES/15-word-counter/spec.json" \
  > "$WORK/17.out" 2> "$WORK/17.err" || { cat "$WORK/17.err"; fail "case 17: second run failed"; }
check "17 second run continues" "$WORK/17.out" "$EXAMPLES/15-word-counter/expected-second-run.txt"
pass "17. the state topic holds one entry per word, and the second run continues from it"

# ---- 18-19. word-probe: the same state, read by another pipeline -------
# SDF has two services here, the second referencing the first's state. In
# moonflux they are two pipelines pointing at one state TOPIC — so the gate
# has to prove two things: the answer is right, and reading is not writing.
DP="$WORK/p29-wordprobe"
"$EXE" pipeline run --data-dir "$DP" --spec "$EXAMPLES/16-word-probe/spec-count.json" \
  > "$WORK/18.counts" 2> "$WORK/18.err" || { cat "$WORK/18.err"; fail "case 18: counting pipeline failed"; }
check "18 per-word stream" "$WORK/18.counts" "$EXAMPLES/16-word-probe/expected-counts-stream.txt"
"$EXE" consume --topic count-per-word --from 0 --data-dir "$DP" 2>/dev/null | cut -f3,4 | sort \
  > "$WORK/18.state"
check "18 per-word state" "$WORK/18.state" "$EXAMPLES/16-word-probe/expected-state.txt"
BEFORE="$("$EXE" consume --topic count-per-word --from 0 --data-dir "$DP" 2>/dev/null | wc -l | tr -d ' ')"
"$EXE" pipeline run --data-dir "$DP" --spec "$EXAMPLES/16-word-probe/spec-probe.json" \
  > "$WORK/18.probe" 2> "$WORK/18.probe.err" || { cat "$WORK/18.probe.err"; fail "case 18: probe pipeline failed"; }
check "18 probe answers" "$WORK/18.probe" "$EXAMPLES/16-word-probe/expected-probe.txt"
pass "18. a second pipeline read the same state topic and answered per word, byte for byte"

AFTER="$("$EXE" consume --topic count-per-word --from 0 --data-dir "$DP" 2>/dev/null | wc -l | tr -d ' ')"
[ "$AFTER" = "$BEFORE" ] ||
  fail "the probe wrote to the state topic ($BEFORE -> $AFTER records): reading must not write"
"$EXE" pipeline run --data-dir "$DP" --spec "$EXAMPLES/16-word-probe/spec-probe-extra.json" \
  > "$WORK/19.probe" 2> "$WORK/19.probe.err" || { cat "$WORK/19.probe.err"; fail "case 19: probe failed"; }
check "19 a word the state never saw" "$WORK/19.probe" "$EXAMPLES/16-word-probe/expected-probe-extra.txt"
pass "19. the probe wrote no state ($BEFORE records before and after) and reported the missing-word default"

# ---- 20-22. bank-processing: balances, and who is in the red -----------
# The reference's eight sample events, verbatim and in timestamp order. A
# transfer touches two accounts, which is why it becomes two keyed records:
# the state layer fetches state per record key, so one record could not
# compute both balances.
DBANK="$WORK/p29-bank"
"$EXE" pipeline run --data-dir "$DBANK" --spec "$EXAMPLES/17-bank-processing/spec-balance.json" \
  > "$WORK/20.balances" 2> "$WORK/20.err" || { cat "$WORK/20.err"; fail "case 20: balance run failed"; }
check "20 balance stream" "$WORK/20.balances" "$EXAMPLES/17-bank-processing/expected-balance.txt"
pass "20. every affected account's balance, byte for byte, from the reference's own sample events"

"$EXE" consume --topic account-balance --from 0 --data-dir "$DBANK" 2>/dev/null \
  | awk -F'	' '{last[$3]=$4} END {for (k in last) print k"\t"last[k]}' | sort > "$WORK/21.final"
check "21 final balances" "$WORK/21.final" "$EXAMPLES/17-bank-processing/expected-final-balances.txt"
"$EXE" consume --topic account-balance --from 0 --data-dir "$DBANK" 2>/dev/null | cut -f3,4 | sort > "$WORK/21.state"
check "21 state history" "$WORK/21.state" "$EXAMPLES/17-bank-processing/expected-state.txt"
pass "21. the state topic saw every write, and converges to 770/2610 per account"

"$EXE" pipeline run --data-dir "$WORK/p29-bank-over" --spec "$EXAMPLES/17-bank-processing/spec-overdraft.json" \
  > "$WORK/22.overdraft" 2> "$WORK/22.err" || { cat "$WORK/22.err"; fail "case 22: overdraft run failed"; }
check "22 overdraft stream" "$WORK/22.overdraft" "$EXAMPLES/17-bank-processing/expected-overdraft.txt"
grep -q '"overdraft":true' "$WORK/22.overdraft" || fail "case 22: the overdraft line is not flagged"
grep -q '"balance":-130' "$WORK/22.overdraft" || fail "case 22: the overdrawn balance is wrong"
pass "22. an overdrawing withdrawal is flagged and selected: one line, balance -130"

# ---- 23-25. unreal-engine-analytics: labels, and 10-second windows ----
# The reference's own 183-event sample, verbatim. Its windowed dataflow
# reads a CLOCK to stamp records; our transforms do not (kernel red line),
# so the windowed fixture carries event time instead — that is why leg 25
# uses events-windowed.jsonl (the same events plus `ts`).
DUE="$WORK/p29-unreal"
"$EXE" pipeline run --data-dir "$DUE" --spec "$EXAMPLES/18-unreal-engine-analytics/spec-counters.json" \
  > "$WORK/23.counts" 2> "$WORK/23.err" || { cat "$WORK/23.err"; fail "case 23: unreal counters failed"; }
check "23 per-event count stream" "$WORK/23.counts" "$EXAMPLES/18-unreal-engine-analytics/expected-counters.txt"
"$EXE" consume --topic event-counts --from 0 --data-dir "$DUE" 2>/dev/null \
  | awk -F'	' '{last[$3]=$4} END {for (k in last) print k"\t"last[k]}' | sort > "$WORK/23.final"
check "23 final label counts" "$WORK/23.final" "$EXAMPLES/18-unreal-engine-analytics/expected-final-counts.txt"
pass "23. every event of the reference's own sample counted under its label, byte for byte"

grep -q "^other	16$" "$WORK/23.final" ||
  fail "case 24: the label table's catch-all did not collect beginPlay/endPlay (expected other=16)"
grep -qE "^jump	113$" "$WORK/23.final" || fail "case 24: jump is not 113"
grep -qE "^(beginPlay|endPlay)	" "$WORK/23.final" &&
  fail "case 24: an unmapped name became its own label instead of falling into the default"
pass "24. unmapped event names fall into \`other\` (beginPlay + endPlay = 16), not into labels of their own"

DUW="$WORK/p29-unreal-window"
"$EXE" pipeline run --data-dir "$DUW" --spec "$EXAMPLES/18-unreal-engine-analytics/spec-windows.json" \
  > "$WORK/25.windows" 2> "$WORK/25.err" || { cat "$WORK/25.err"; fail "case 25: unreal windows failed"; }
check "25 windowed count stream" "$WORK/25.windows" "$EXAMPLES/18-unreal-engine-analytics/expected-windows.txt"
"$EXE" consume --topic event-window-counts --from 0 --data-dir "$DUW" 2>/dev/null | cut -f3,4 | sort \
  > "$WORK/25.state"
check "25 window state entries" "$WORK/25.state" "$EXAMPLES/18-unreal-engine-analytics/expected-window-state.txt"
grep -q "@1700000000000" "$WORK/25.state" || fail "case 25: the window start is not visible in the state key"
pass "25. 10-second tumbling windows: the same label in two windows is two independent state entries"

# ---- 26-29. car-processing: speed, locations, colour windows, plates --
# The fixture is SYNTHETIC (the reference reads a live generator); it follows
# the schema its README documents, spread over three 30-second windows, and
# contains exactly one plate that is registered to a different car.
DCAR="$WORK/p29-car"
"$EXE" pipeline run --data-dir "$DCAR" --spec "$EXAMPLES/19-car-processing/spec-speed.json" \
  > "$WORK/26.speed" 2> "$WORK/26.err" || { cat "$WORK/26.err"; fail "case 26: speed run failed"; }
check "26 speeding selection" "$WORK/26.speed" "$EXAMPLES/19-car-processing/expected-speed.txt"
[ "$(wc -l < "$WORK/26.speed" | tr -d ' ')" = "6" ] || fail "case 26: expected 6 speeding cars"
pass "26. mph > 60 selects exactly the six speeding cars, byte for byte"

for loc in sunnyvale saratoga; do
  "$EXE" pipeline run --data-dir "$DCAR" --spec "$EXAMPLES/19-car-processing/spec-location-$loc.json" \
    > "$WORK/27.$loc" 2> "$WORK/27.$loc.err" || { cat "$WORK/27.$loc.err"; fail "case 27: $loc run failed"; }
  check "27 $loc selection" "$WORK/27.$loc" "$EXAMPLES/19-car-processing/expected-location-$loc.txt"
done
cat "$WORK/27.sunnyvale" "$WORK/27.saratoga" | sort > "$WORK/27.both"
sort "$WORK/26.speed" > "$WORK/26.sorted"
diff -u "$WORK/26.sorted" "$WORK/27.both" ||
  fail "case 27: the two locations do not add up to the speeding set (disjoint and complete)"
pass "27. the two location pipelines are disjoint and together cover the speeding set"

"$EXE" pipeline run --data-dir "$DCAR" --spec "$EXAMPLES/19-car-processing/spec-color-windows.json" \
  > "$WORK/28.windows" 2> "$WORK/28.err" || { cat "$WORK/28.err"; fail "case 28: colour windows failed"; }
check "28 colour window stream" "$WORK/28.windows" "$EXAMPLES/19-car-processing/expected-color-windows.txt"
"$EXE" consume --topic count-by-color --from 0 --data-dir "$DCAR" 2>/dev/null | cut -f3,4 | sort \
  > "$WORK/28.state"
check "28 colour window state" "$WORK/28.state" "$EXAMPLES/19-car-processing/expected-color-state.txt"
grep -q "@1710432" "$WORK/28.state" || fail "case 28: the window start is not in the state key"
pass "28. ISO-8601 event time puts each car in its 30-second window, one state entry per colour@window"

DCARS="$WORK/p29-car-plates"
"$EXE" pipeline run --data-dir "$DCARS" --spec "$EXAMPLES/19-car-processing/spec-licenses.json" \
  > "$WORK/29.load" 2> "$WORK/29.err" || { cat "$WORK/29.err"; fail "case 29: license load failed"; }
check "29 registered plates" "$WORK/29.load" "$EXAMPLES/19-car-processing/expected-licenses.txt"
"$EXE" consume --topic license-plates --from 0 --data-dir "$DCARS" 2>/dev/null | cut -f3,4 | sort \
  > "$WORK/29.table"
check "29 license table rows" "$WORK/29.table" "$EXAMPLES/19-car-processing/expected-license-state.txt"
"$EXE" pipeline run --data-dir "$DCARS" --spec "$EXAMPLES/19-car-processing/spec-stolen.json" \
  > "$WORK/29.stolen" 2> "$WORK/29.stolen.err" || { cat "$WORK/29.stolen.err"; fail "case 29: stolen check failed"; }
check "29 stolen plate" "$WORK/29.stolen" "$EXAMPLES/19-car-processing/expected-stolen.txt"
"$EXE" consume --topic license-plates --from 0 --data-dir "$DCARS" 2>/dev/null | cut -f3,4 | sort \
  > "$WORK/29.after"
diff -u "$WORK/29.table" "$WORK/29.after" ||
  fail "case 29: the stolen-plate check wrote to the table it was checking"
pass "29. one plate registered to a different car is reported, and the read-only check left the table untouched"

# ---- 30-31. helsinki-transit: clean, then average per vehicle window ---
# The fixture's first record is the reference package's own sample event
# (vehicle 1271, route 1040, speed 8.09); three of the ten are incomplete
# (missing speed / lat / long) because dropping those is clean-events' job.
DHEL="$WORK/p29-helsinki"
"$EXE" pipeline run --data-dir "$DHEL" --spec "$EXAMPLES/20-helsinki-transit/spec-vehicle-stats.json" \
  > "$WORK/30.stream" 2> "$WORK/30.err" || { cat "$WORK/30.err"; fail "case 30: helsinki run failed"; }
check "30 vehicle-speed stream" "$WORK/30.stream" "$EXAMPLES/20-helsinki-transit/expected-stream.txt"
[ "$(wc -l < "$WORK/30.stream" | tr -d ' ')" = "7" ] ||
  fail "case 30: expected 7 records out of 10 (three incomplete events must be dropped)"
grep -q "avg_speed" "$WORK/30.stream" || fail "case 30: the average field is missing"
pass "30. the three incomplete events are dropped and the other seven get a running average per vehicle@window"

"$EXE" consume --topic vehicle-speed --from 0 --data-dir "$DHEL" 2>/dev/null | cut -f3,4 | sort \
  > "$WORK/31.state"
check "31 vehicle window state" "$WORK/31.state" "$EXAMPLES/20-helsinki-transit/expected-state.txt"
grep -q "^1271@1748558765000	27.41,2$" "$WORK/31.state" ||
  fail "case 31: the state is not sum,count for the two-sample window (expected 27.41,2)"
pass "31. the state keeps sum and count (27.41,2), which is why 11.5 then 13.705 can be checked by hand"

# ---- 32-33. ny-transit: average tip per pickup zone, 30-second windows --
# TLC-shaped trip records (the reference links the public dataset's schema;
# the fixture follows it and carries UTC instants, because our windows refuse
# to invent an offset for a naive local timestamp).
DNY="$WORK/p29-ny-transit"
"$EXE" pipeline run --data-dir "$DNY" --spec "$EXAMPLES/21-ny-transit/spec-pu-tips.json" \
  > "$WORK/32.stream" 2> "$WORK/32.err" || { cat "$WORK/32.err"; fail "case 32: ny-transit run failed"; }
check "32 zone tip averages" "$WORK/32.stream" "$EXAMPLES/21-ny-transit/expected-stream.txt"
grep -q '"key":"ZoneA@' "$WORK/32.stream" || fail "case 32: the zone window key is missing"
grep -q '"avg_tip"' "$WORK/32.stream" || fail "case 32: the average field is missing"
pass "32. eight trips land in their zone@30s windows and report the running average tip"

"$EXE" consume --topic pu-tips --from 0 --data-dir "$DNY" 2>/dev/null | cut -f3,4 | sort \
  > "$WORK/33.state"
check "33 zone window state" "$WORK/33.state" "$EXAMPLES/21-ny-transit/expected-state.txt"
grep -q "^ZoneA@1710432750000	8,2$" "$WORK/33.state" ||
  fail "case 33: the state is not sum,count for the two-trip zone window (expected 8,2)"
pass "33. the state keeps sum and count (8,2), which is why the running 3 then 4 can be checked by hand"

echo "E2E-P29-EXAMPLES: 33 legs green (21 case specs across 21 example applications)"
