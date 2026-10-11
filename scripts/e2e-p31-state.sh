#!/bin/bash
# E2E-P31: keyed state end to end (ABI v3, P30/T114).
#
# The design (docs/operator-abi-v3-state.md) says state is a *keyed log*
# the host caches, never a second source of truth. Every leg below is
# that claim turned into something falsifiable:
#
#   1  survives a process boundary   run twice: the counts continue, and
#                                    the state topic (not memory) is why
#   2  compaction keeps the latest    force segments to seal, compact, run
#                                    again: the view rebuilt from the
#                                    compacted topic continues correctly,
#                                    and a read below the new floor is a
#                                    structured refusal
#   3  determinism                    two fresh data dirs, same input:
#                                    identical sink output and identical
#                                    state values
#   4  a keyless record is refused    by name, with nothing sunk
#   5  the view cap refuses early     before anything is written, naming
#                                    the limit
#   6  fail-closed                    a refused batch leaves no output and
#                                    no state records
#   7  the v3 pair rule               the ABI probe (which also checks the
#                                    published C header) stays green
#   8  v1 is untouched                an ordinary batch operator still runs
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
EXE="${MOONFLUX_EXE:-$ROOT/_build/native/debug/build/apps/cli/cli.exe}"
WORK="$(mktemp -d /tmp/moonflux-p31-state.XXXXXX)"
PORT="${MOONFLUX_P31_PORT:-20021}"
PIDS=()

cleanup() {
  for pid in "${PIDS[@]:-}"; do kill "$pid" 2>/dev/null || true; done
  for pid in $(lsof -ti ":$PORT" -sTCP:LISTEN 2>/dev/null); do kill "$pid" 2>/dev/null || true; done
  rm -rf "$WORK"
}
trap cleanup EXIT

fail() { echo "E2E-P31-STATE FAIL: $*" >&2; exit 1; }
pass() { echo "E2E-P31-STATE PASS: $*"; }

wait_listen() {
  for _ in $(seq 1 60); do
    lsof -i ":$1" -sTCP:LISTEN > /dev/null 2>&1 && return 0
    sleep 0.1
  done
  return 1
}

check_values() { # $1 = label, $2 = file holding one value per line, $3 = expected newline-joined
  local got
  got="$(cat "$2")"
  [ "$got" = "$3" ] || fail "$1: got [$got], expected [$3]"
}

[ -x "$EXE" ] || fail "cli binary not found at $EXE (run: moon build --target native)"
for op in operator-wordkeys operator-counter; do
  [ -f "$ROOT/_build/wasm/debug/build/apps/$op/$op.wasm" ] ||
    fail "missing $op.wasm — run: scripts/build-operators.sh"
done

# ---- fixtures ----------------------------------------------------------
printf 'the cat the dog the\n' > "$WORK/sentences.txt"
cat > "$WORK/wordcount.json" <<EOF
{
  "apiVersion": "moonflux.io/v1alpha1",
  "kind": "Pipeline",
  "metadata": { "name": "p31-wordcount" },
  "spec": {
    "source": { "type": "file", "path": "$WORK/sentences.txt" },
    "topic": { "name": "words" },
    "state": { "topic": "wordcount-state" },
    "transforms": [
      {
        "type": "wasm",
        "module": "_build/wasm/debug/build/apps/operator-wordkeys/operator-wordkeys.wasm",
        "config": {}
      },
      {
        "type": "wasm",
        "module": "_build/wasm/debug/build/apps/operator-counter/operator-counter.wasm",
        "config": {}
      }
    ],
    "sink": { "type": "stdout" }
  }
}
EOF
cat > "$WORK/upper.json" <<EOF
{
  "apiVersion": "moonflux.io/v1alpha1",
  "kind": "Pipeline",
  "metadata": { "name": "p31-upper" },
  "spec": {
    "source": { "type": "file", "path": "$WORK/sentences.txt" },
    "topic": { "name": "upper-words" },
    "transforms": [
      {
        "type": "wasm",
        "module": "_build/wasm/debug/build/apps/operator-upper/operator-upper.wasm",
        "config": {}
      }
    ],
    "sink": { "type": "stdout" }
  }
}
EOF
# the counter alone, deliberately without a key-setting operator
cat > "$WORK/keyless.json" <<EOF
{
  "apiVersion": "moonflux.io/v1alpha1",
  "kind": "Pipeline",
  "metadata": { "name": "p31-keyless" },
  "spec": {
    "source": { "type": "file", "path": "$WORK/sentences.txt" },
    "topic": { "name": "keyless-data" },
    "state": { "topic": "keyless-state" },
    "transforms": [
      {
        "type": "wasm",
        "module": "_build/wasm/debug/build/apps/operator-counter/operator-counter.wasm",
        "config": {}
      }
    ],
    "sink": { "type": "stdout" }
  }
}
EOF

# ---- 1. state survives a process boundary ------------------------------
D="$WORK/d1"
# a small roll threshold so each batch's state lands in its own segment:
# leg 2 compacts exactly one of them
MOONFLUX_ROLL_BYTES=20 "$EXE" pipeline run --data-dir "$D" --spec "$WORK/wordcount.json" \
  > "$WORK/run1.out" 2> "$WORK/run1.err" || { cat "$WORK/run1.err"; fail "run 1 failed"; }
check_values "1 first run" "$WORK/run1.out" "$(printf '1\n1\n2\n1\n3')"
MOONFLUX_ROLL_BYTES=20 "$EXE" pipeline run --data-dir "$D" --spec "$WORK/wordcount.json" \
  > "$WORK/run2.out" 2> "$WORK/run2.err" || { cat "$WORK/run2.err"; fail "run 2 failed"; }
check_values "1 second run continues" "$WORK/run2.out" "$(printf '4\n2\n5\n2\n6')"
"$EXE" consume --topic wordcount-state --from 0 --data-dir "$D" 2>/dev/null | cut -f4 > "$WORK/state-after-2.txt"
check_values "1 state topic holds one write per key per batch" "$WORK/state-after-2.txt" "$(printf '3\n1\n1\n6\n2\n2')"
pass "1. the counts continue across processes because the state topic, not memory, holds them"

# ---- 2. compaction keeps the latest per key ----------------------------
"$EXE" serve --data-dir "$D" --listen "127.0.0.1:$PORT" > "$WORK/serve.log" 2>&1 &
PIDS+=("$!")
wait_listen "$PORT" || { cat "$WORK/serve.log"; fail "serve did not start"; }
MOONFLUX_ROLL_BYTES=20 "$EXE" cluster compact --remote "127.0.0.1:$PORT" --topic wordcount-state \
  > "$WORK/compact.txt" 2>&1 || { cat "$WORK/compact.txt"; fail "compact failed"; }
grep -qE "compacted [1-9][0-9]* segment" "$WORK/compact.txt" ||
  { cat "$WORK/compact.txt"; fail "expected the sealed segment to be compacted"; }
grep -q "3 records dropped" "$WORK/compact.txt" ||
  { cat "$WORK/compact.txt"; fail "expected the superseded batch to be dropped (3 records)"; }
# the floor moved: reading below it is a refusal, not an empty window
"$EXE" consume --topic wordcount-state --from 0 --data-dir "$D" > "$WORK/from0.out" 2> "$WORK/from0.err"
[ -s "$WORK/from0.out" ] && fail "a read below the new floor produced records"
grep -q "OffsetOutOfRange" "$WORK/from0.err" ||
  { cat "$WORK/from0.err"; fail "a read below the new floor was not refused by name"; }
# and the view rebuilt from the compacted topic keeps counting correctly
MOONFLUX_ROLL_BYTES=20 "$EXE" pipeline run --data-dir "$D" --spec "$WORK/wordcount.json" \
  > "$WORK/run3.out" 2> "$WORK/run3.err" || { cat "$WORK/run3.err"; fail "run 3 (after compaction) failed"; }
check_values "2 run after compaction" "$WORK/run3.out" "$(printf '7\n3\n8\n3\n9')"
pass "2. compaction collapsed the superseded batch, the floor moved, and the rebuilt view continued"

# ---- 3. determinism ----------------------------------------------------
MOONFLUX_ROLL_BYTES=20 "$EXE" pipeline run --data-dir "$WORK/dA" --spec "$WORK/wordcount.json" \
  > "$WORK/A.out" 2>/dev/null || fail "determinism run A failed"
MOONFLUX_ROLL_BYTES=20 "$EXE" pipeline run --data-dir "$WORK/dB" --spec "$WORK/wordcount.json" \
  > "$WORK/B.out" 2>/dev/null || fail "determinism run B failed"
diff -u "$WORK/A.out" "$WORK/B.out" || fail "two fresh runs disagreed on the sink output"
"$EXE" consume --topic wordcount-state --from 0 --data-dir "$WORK/dA" 2>/dev/null | cut -f1,3,4 > "$WORK/A.state"
"$EXE" consume --topic wordcount-state --from 0 --data-dir "$WORK/dB" 2>/dev/null | cut -f1,3,4 > "$WORK/B.state"
diff -u "$WORK/A.state" "$WORK/B.state" || fail "two fresh runs disagreed on the state topic"
pass "3. same input, fresh data dirs: identical output at identical offsets"

# ---- 4 & 6. a keyless record is refused, and nothing is written ---------
D="$WORK/dKeyless"
"$EXE" pipeline run --data-dir "$D" --spec "$WORK/keyless.json" \
  > "$WORK/keyless.out" 2> "$WORK/keyless.err"
grep -q "needs a key" "$WORK/keyless.err" ||
  { cat "$WORK/keyless.err"; fail "the keyless refusal does not name the reason"; }
[ -s "$WORK/keyless.out" ] && fail "a refused batch still reached the sink"
KEYLESS_STATE="$("$EXE" consume --topic keyless-state --from 0 --data-dir "$D" 2>/dev/null | wc -l | tr -d ' ')"
[ "$KEYLESS_STATE" = "0" ] || fail "a refused batch wrote $KEYLESS_STATE state records"
pass "4/6. a stateful node with no key to count by refuses by name, sinks nothing and writes no state"

# ---- 5. the view cap refuses before anything is written ----------------
D="$WORK/dCap"
MOONFLUX_STATE_KEYS=1 "$EXE" pipeline run --data-dir "$D" --spec "$WORK/wordcount.json" \
  > "$WORK/cap.out" 2> "$WORK/cap.err"
grep -q "state view is full" "$WORK/cap.err" ||
  { cat "$WORK/cap.err"; fail "the view cap refusal does not name the limit"; }
grep -q "no state was written" "$WORK/cap.err" ||
  { cat "$WORK/cap.err"; fail "the cap refusal does not promise what it did"; }
CAP_STATE="$("$EXE" consume --topic wordcount-state --from 0 --data-dir "$D" 2>/dev/null | wc -l | tr -d ' ')"
[ "$CAP_STATE" = "0" ] || fail "the cap refusal wrote $CAP_STATE state records anyway"
pass "5. the view cap refuses before the write, and says so"

# ---- 7. the v3 pair rule (and the header check) ------------------------
python3 tools/probe_operator_exports.py > "$WORK/probe.out" 2>&1 ||
  { cat "$WORK/probe.out"; fail "the ABI probe is red"; }
grep -q "published header" "$WORK/probe.out" ||
  { cat "$WORK/probe.out"; fail "the probe did not check the published header"; }
pass "7. the ABI probe (v1 signatures + v2/v3 pairs + published header) is green"

# ---- 8. an ordinary batch operator is untouched ------------------------
"$EXE" pipeline run --data-dir "$WORK/dUpper" --spec "$WORK/upper.json" > "$WORK/upper.out" 2> "$WORK/upper.err" ||
  { cat "$WORK/upper.err"; fail "a v1-only operator pipeline failed"; }
check_values "8 v1 operator" "$WORK/upper.out" "THE CAT THE DOG THE"
pass "8. a v1 batch operator still runs: the state addition changed no existing path"

echo "E2E-P31-STATE: 8 legs green (keyed state end to end)"
