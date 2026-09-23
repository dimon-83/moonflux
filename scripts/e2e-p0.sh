#!/bin/bash
# P0 gate: end-to-end demo, reproducible.
#   file source -> topic log -> stdout sink, via BOTH the local CLI
#   path and the session-protocol (serve + remote) path.
# Exits non-zero on any mismatch.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# the debug build is what `moon build --target native` produces, so it is
# the artifact this gate means to test (see the same note in the other
# gates: preferring a stray release binary once tested a stale session)
EXE="${MOONFLUX_EXE:-$ROOT/_build/native/debug/build/apps/cli/cli.exe}"

if [ ! -x "$EXE" ]; then
  EXE="$ROOT/_build/native/release/build/apps/cli/cli.exe"
fi
if [ ! -x "$EXE" ]; then
  echo "cli executable not found; run: moon build --target native" >&2
  exit 1
fi

WORK="$(mktemp -d /tmp/moonflux-e2e.XXXXXX)"
trap 'kill "$SERVER_PID" 2>/dev/null || true; rm -rf "$WORK"' EXIT

PORT="${MOONFLUX_E2E_PORT:-19231}"
SERVER_PID=""

printf 'alpha\nbravo\ncharlie\ndelta\necho\n' > "$WORK/events.txt"
printf 'alpha\t[0-9]+\t\talpha\nbravo\t[0-9]+\t\tbravo\ncharlie\t[0-9]+\t\tcharlie\ndelta\t[0-9]+\t\tdelta\necho\t[0-9]+\t\techo\n' > "$WORK/expected-regex.txt"

fail() { echo "E2E-P0 FAIL: $*" >&2; exit 1; }
pass() { echo "E2E-P0 PASS: $*"; }

# ---------- path 1: local CLI (file source -> log -> stdout sink) ----------
"$EXE" produce --topic e2e --file "$WORK/events.txt" --data-dir "$WORK/local-data" \
  | grep -q "produced 5 records" || fail "local produce output"
"$EXE" produce --topic e2e --file "$WORK/events.txt" --data-dir "$WORK/local-data" \
  | grep -q "offsets 5\.\.10" || fail "local produce second batch offsets"

# consume replays values in order; strip the variable timestamp column
"$EXE" consume --topic e2e --data-dir "$WORK/local-data" \
  | awk -F'\t' '{print $1 "\t" $4}' > "$WORK/local-out.txt"
# expected: offsets 0..9 paired with the 10 replayed lines in order
paste <(seq 0 9) <(cat "$WORK/events.txt" "$WORK/events.txt") \
  | awk -F'\t' '{print $1 "\t" $2}' > "$WORK/local-expected.txt"
diff -u "$WORK/local-expected.txt" "$WORK/local-out.txt" || fail "local consume content"
pass "local path: file -> produce -> consume matches (10 records, offsets 0..9)"

# replay from the middle
"$EXE" consume --topic e2e --from 7 --data-dir "$WORK/local-data" \
  | awk -F'\t' '{print $1 "\t" $4}' > "$WORK/local-tail.txt"
printf '7\tcharlie\n8\tdelta\n9\techo\n' > "$WORK/local-tail-expected.txt"
diff -u "$WORK/local-tail-expected.txt" "$WORK/local-tail.txt" || fail "local consume --from 7"
pass "local path: --from 7 replays offsets 7..9"

# ---------- path 2: session protocol (serve + remote produce/consume) ----------
"$EXE" serve --data-dir "$WORK/remote-data" --listen "127.0.0.1:$PORT" \
  > "$WORK/serve.log" 2>&1 &
SERVER_PID=$!

for _ in $(seq 1 50); do
  if lsof -i ":$PORT" -sTCP:LISTEN >/dev/null 2>&1; then break; fi
  sleep 0.1
done
lsof -i ":$PORT" -sTCP:LISTEN >/dev/null 2>&1 || fail "server did not start on $PORT"

"$EXE" produce --topic remote --file "$WORK/events.txt" --remote "127.0.0.1:$PORT" \
  | grep -q "offsets 0\.\.5" || fail "remote produce first batch"
"$EXE" produce --topic remote --file "$WORK/events.txt" --remote "127.0.0.1:$PORT" \
  | grep -q "offsets 5\.\.10" || fail "remote produce second batch"

"$EXE" consume --topic remote --remote "127.0.0.1:$PORT" \
  | awk -F'\t' '{print $1 "\t" $4}' > "$WORK/remote-out.txt"
diff -u "$WORK/local-expected.txt" "$WORK/remote-out.txt" || fail "remote consume content"
pass "remote path: serve <- produce --remote <- consume --remote matches"

# server persisted to the same on-disk format: verify by local consume
"$EXE" consume --topic remote --data-dir "$WORK/remote-data" \
  | awk -F'\t' '{print $1 "\t" $4}' > "$WORK/remote-local-read.txt"
diff -u "$WORK/local-expected.txt" "$WORK/remote-local-read.txt" || fail "server data dir readable by local consume"
pass "interoperability: server-written segment file replays via local consume"

# ---------- path 3: the topic family on a standalone broker (P18) ------
# A standalone broker owns its own declarations (the same store its
# function sets use), lists the *union* of declared and auto-created
# topics (produce auto-creates; a listing that omits those lies by
# omission), and its delete is the first second write path P16
# anticipated: the log cache lets go of the handles before the files
# go, so no cached entry can outlive the data it describes.
"$EXE" topic create --name declared --partitions 2 --replication-factor 2 \
  --remote "127.0.0.1:$PORT" > "$WORK/rf2.out" 2>&1 \
  && fail "a replication factor of 2 was accepted on a one-node serve"
grep -q "needs a cluster" "$WORK/rf2.out" \
  || fail "the rf refusal does not say why: $(cat "$WORK/rf2.out")"
"$EXE" topic create --name declared --partitions 2 --replication-factor 1 \
  --remote "127.0.0.1:$PORT" > /dev/null || fail "topic create on serve failed"
TOPICS="$("$EXE" topic list --remote "127.0.0.1:$PORT")"
echo "$TOPICS" | grep '^declared' | grep -q 'partitions=2' \
  || fail "the declared topic is not listed: $TOPICS"
echo "$TOPICS" | grep '^remote' | grep -q 'partitions=1' \
  || fail "the auto-created topic is missing from the listing: $TOPICS"
pass "topic family: serve declares, and its listing is declared + auto-created"

"$EXE" topic delete --name remote --remote "127.0.0.1:$PORT" > /dev/null \
  || fail "topic delete on serve failed"
[ ! -d "$WORK/remote-data/topics/remote" ] \
  || fail "the deleted topic's data directory is still there"
"$EXE" topic list --remote "127.0.0.1:$PORT" | grep -q '^remote' \
  && fail "the deleted topic is still listed"
grep -q "cached log handle(s) evicted" "$WORK/serve.log" \
  || fail "the delete never evicted the cached log handles"
printf 'after\n' > "$WORK/after.txt"
"$EXE" produce --topic remote --file "$WORK/after.txt" --remote "127.0.0.1:$PORT" \
  | grep -q "offsets 0\.\.1" || fail "a re-created topic did not start at offset 0"
pass "topic family: delete removes the data (cache evicted first), and a re-create starts at 0"

# group coordination is the control plane's (P9); a standalone serve
# says so instead of "unknown command"
"$EXE" group describe --name g --remote "127.0.0.1:$PORT" > "$WORK/group.out" 2>&1 \
  && fail "a group command was accepted by a standalone serve"
grep -q "group coordination lives with the control plane" "$WORK/group.out" \
  || fail "the group refusal does not say where the capability lives: $(cat "$WORK/group.out")"
pass "group family: a standalone serve refuses coordination with a pointer to the control plane"

kill "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true

echo "E2E-P0: all green"
