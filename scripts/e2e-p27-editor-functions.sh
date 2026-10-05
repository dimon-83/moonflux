#!/bin/bash
# P27 gate (the milestone's own): the editor's function-set UI — panel,
# form, expr reference, drift — through a real browser, then assert the
# *data* it produced.
#
#   setup   build the editor kernel (js), stage the page, start the
#           broker (`serve --ws`) and a static server, print the URL
#   bump    publish revision 2 of the gate's set via the CLI (the drift
#           leg's input: the set moves *behind the page's back*)
#   verify  the loop's end state on the server: the panel's CREATE
#           reached the node over WebSocket, the picker's reference is
#           in the applied spec, the re-apply bound revision 2, and the
#           consumed history was re-rendered by the new rules
#
# The browser phases are driven by whoever runs the gate (the agent in
# a session, or a human with the printed URL); two rounds of drive are
# needed (one per revision). Everything else is this script.
#
# Usage:
#   scripts/e2e-p27-editor-functions.sh setup   # print the URL, leave everything running
#   … drive round 1 (create set → pick → deploy → run → consume) …
#   scripts/e2e-p27-editor-functions.sh bump    # the set moves to revision 2
#   … drive round 2 (refresh panel → see the drift marker → re-deploy → run "beta") …
#   scripts/e2e-p27-editor-functions.sh verify
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXE="${MOONFLUX_EXE:-$ROOT/_build/native/debug/build/apps/cli/cli.exe}"
[ -x "$EXE" ] || EXE="$ROOT/_build/native/release/build/apps/cli/cli.exe"
[ -x "$EXE" ] || { echo "cli executable not found; run: moon build --target native" >&2; exit 1; }

WORK="${MOONFLUX_P27_WORK:-/tmp/moonflux-p27-editor}"
BROKER_PORT="${MOONFLUX_P27_BROKER_PORT:-19771}"
PAGE_PORT="${MOONFLUX_P27_PAGE_PORT:-19772}"
SET_NAME="editor-fns"
PAGE_DIR="$WORK/page"
STATE="$WORK/state.env"

fail() { echo "E2E-P27-EDITOR FAIL: $*" >&2; exit 1; }
pass() { echo "E2E-P27-EDITOR PASS: $*"; }

# The asset document, per revision: shout(x) re-rendered. Revision 1
# exclaims, revision 2 asks — a consumed record's suffix says which
# revision the reading path bound.
write_asset() { # $1 = out path, $2 = body
  python3 - "$1" "$2" <<'PY'
import json, sys
doc = {
    "name": "editor-fns",
    "version": 1,
    "functions": [
        {"name": "shout", "params": ["x"], "body": sys.argv[2],
         "description": "the editor's gate function"},
    ],
}
open(sys.argv[1], "w").write(json.dumps(doc, indent=2))
PY
}

load_state() {
  [ -f "$STATE" ] || fail "no state file — run setup first"
  # shellcheck disable=SC1090
  source "$STATE"
}

setup() {
  rm -rf "$WORK"
  mkdir -p "$PAGE_DIR" "$WORK/broker"

  echo "[1/3] building the editor kernel (js target)"
  moon build --target js apps/editor-kernel > /dev/null 2>&1 \
    || fail "the editor kernel does not build for js"
  local kernel_js
  kernel_js="$(find "$ROOT/_build/js" -name editor-kernel.js | head -1)"
  [ -n "$kernel_js" ] || fail "no editor-kernel.js artifact"
  cp "$kernel_js" "$PAGE_DIR/editor-kernel.js"
  cp "$ROOT/web/editor/index.html" "$PAGE_DIR/index.html"
  # artifact freshness: a kernel without the function-set surface leaves
  # the panel silently missing — the page asserts ABI 2, and so does this
  grep -q "mf_editor_build_function_set" "$PAGE_DIR/editor-kernel.js" \
    || fail "the staged kernel predates the function-set surface (ABI 2)"

  echo "[2/3] starting the broker (serve --ws) on $BROKER_PORT"
  "$EXE" serve --data-dir "$WORK/broker" --listen "127.0.0.1:$BROKER_PORT" --ws \
    > "$WORK/broker.log" 2>&1 &
  echo "$!" > "$WORK/broker.pid"

  echo "[3/3] serving the editor page on $PAGE_PORT"
  ( cd "$PAGE_DIR" && python3 -m http.server "$PAGE_PORT" --bind 127.0.0.1 ) \
    > "$WORK/page.log" 2>&1 &
  echo "$!" > "$WORK/page.pid"

  for port in "$BROKER_PORT" "$PAGE_PORT"; do
    for _ in $(seq 1 60); do
      lsof -i ":$port" -sTCP:LISTEN > /dev/null 2>&1 && break
      sleep 0.1
    done
    lsof -i ":$port" -sTCP:LISTEN > /dev/null 2>&1 || fail "nothing listening on :$port"
  done

  cat > "$STATE" <<EOF
WORK=$WORK
BROKER_PORT=$BROKER_PORT
TOKEN=P27-EDITOR-OK
EOF
  echo
  echo "  editor:  http://127.0.0.1:$PAGE_PORT/index.html?broker=$BROKER_PORT"
  echo "  broker:  ws://127.0.0.1:$BROKER_PORT  (serve --ws)"
  echo
  echo "  drive round 1:"
  echo "    1. function sets → new set: name '$SET_NAME', function"
  echo "       shout(x) = upper(x) + \"!\"  → deploy set"
  echo "    2. add an expr transform, expr 'shout(value)', pick '$SET_NAME'"
  echo "       in the node's function-set dropdown"
  echo "    3. records = 'alpha'; deploy; run; consume → 'ALPHA!' in the table"
  echo
  echo "  then: scripts/e2e-p27-editor-functions.sh bump"
  echo "  drive round 2: refresh the panel (drift marker appears), re-deploy,"
  echo "    records = 'beta', run, consume → 'BETA?'"
  echo
  echo "  then: scripts/e2e-p27-editor-functions.sh verify"
}

bump() {
  load_state
  write_asset "$WORK/fns-r2.json" 'upper(x) + "?"'
  local out
  out="$("$EXE" function-set create --file "$WORK/fns-r2.json" --remote "127.0.0.1:$BROKER_PORT")" \
    || fail "the bump's create failed: $out"
  echo "$out" | grep -q "updated function set $SET_NAME at revision 2" \
    || fail "expected '$SET_NAME' at revision 2, got: $out"
  pass "the set moved behind the page's back: $SET_NAME is now at revision 2"
}

verify() {
  load_state

  # 1. the panel's CREATE reached the node over WebSocket: the set is
  #    in the node's store with one function
  local list
  list="$("$EXE" function-set list --remote "127.0.0.1:$BROKER_PORT")" \
    || fail "function-set list failed"
  echo "$list" | grep -q "^$SET_NAME	revision=2	functions=1" \
    || fail "expected '$SET_NAME revision=2 functions=1' in: $list"
  pass "the panel's create reached the node over WebSocket ($SET_NAME, 1 function, revision 2)"

  # 2. the applied topology references the set and binds revision 2 —
  #    the picker's choice went graph → build_spec → apply, and the
  #    round-2 re-apply moved the binding from r1 to r2
  python3 - "$WORK/broker/topology.json" <<'PY' || fail "topology.json does not bind $SET_NAME at revision 2"
import json, sys
doc = json.load(open(sys.argv[1]))
refs = [t.get("functions") for t in doc["spec"]["spec"]["transforms"]
        if t.get("type") == "expr"]
assert "editor-fns" in refs, f"spec does not reference editor-fns: {refs}"
bound = {f["name"]: f["revision"] for f in doc["functions"]}
assert bound.get("editor-fns") == 2, f"bound revisions: {bound}"
print("  spec references editor-fns; bound revision = 2")
PY
  pass "the picker's reference is in the applied spec, bound to revision 2 (re-apply moved it)"

  # 3. the consumed history is re-rendered by the bound rules: reading
  #    from 0 after the re-apply turns round 1's ALPHA! into ALPHA? —
  #    the drift leg's whole story in one observation
  local out
  out="$("$EXE" consume --topic editor-events --remote "127.0.0.1:$BROKER_PORT" 2>/dev/null)" \
    || fail "consume failed"
  echo "$out" | cut -f4- | grep -qx "ALPHA?" \
    || { echo "$out"; fail "round 1's record was not re-rendered by revision 2 (no ALPHA?)"; }
  echo "$out" | cut -f4- | grep -qx "BETA?" \
    || { echo "$out"; fail "round 2's record did not come back through the set's function (no BETA?)"; }
  if echo "$out" | cut -f4- | grep -q "!"; then
    fail "stale revision 1 rendering still visible after the re-apply"
  fi
  pass "re-apply rebound the rules: history re-rendered (ALPHA?), new record transformed (BETA?)"
}

cleanup() {
  [ -f "$WORK/broker.pid" ] && kill "$(cat "$WORK/broker.pid")" 2>/dev/null || true
  [ -f "$WORK/page.pid" ] && kill "$(cat "$WORK/page.pid")" 2>/dev/null || true
}

case "${1:-all}" in
  setup) setup ;;
  bump) bump ;;
  verify) verify ;;
  all)
    setup
    echo "waiting for both browser rounds (topology bound to revision 2, up to 15 minutes)…"
    deadline=$((SECONDS + 900))
    while [ "$SECONDS" -lt "$deadline" ]; do
      if [ -f "$WORK/broker/topology.json" ] && \
         python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); b={f["name"]:f["revision"] for f in d["functions"]}; sys.exit(0 if b.get("editor-fns")==2 else 1)' \
           "$WORK/broker/topology.json" 2>/dev/null; then
        break
      fi
      sleep 2
    done
    verify
    cleanup
    ;;
  *) fail "unknown mode '$1' (setup|bump|verify|all)" ;;
esac
