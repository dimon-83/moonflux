#!/bin/bash
# P11 gate: assets live at the control plane, data nodes pull them.
#
#   1. one publish at the control plane, both data nodes adopt it and
#      the pulled pipeline actually runs
#   2. the document is fetched when the revision moves, not every
#      heartbeat (the count of adoptions equals the number of revisions)
#   3. a node that joins later adopts the current revision on its own
#   4. with the control plane gone, nodes keep serving what they have
#      (and say so once, not once per tick)
#   5. a function set created only at the control plane reaches both
#      nodes: the spec that references it compiles and runs there
#   6. revisions never go backwards: a control plane that regresses does
#      not drag a node back with it
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# The debug build is what `moon build --target native` (and `moon test`)
# produce, so it is the artifact every gate here means to test. A release
# binary is only a fallback: preferring it once meant a gate silently
# tested a build from an earlier session.
EXE="${MOONFLUX_EXE:-$ROOT/_build/native/debug/build/apps/cli/cli.exe}"
[ -x "$EXE" ] || EXE="$ROOT/_build/native/release/build/apps/cli/cli.exe"
[ -x "$EXE" ] || { echo "cli executable not found; run: moon build --target native" >&2; exit 1; }

WORK="$(mktemp -d /tmp/moonflux-p11-assets.XXXXXX)"
SC_PORT="${MOONFLUX_P11_SC_PORT:-19651}"
A_PORT="${MOONFLUX_P11_A_PORT:-19652}"
B_PORT="${MOONFLUX_P11_B_PORT:-19653}"
C_PORT="${MOONFLUX_P11_C_PORT:-19654}"
SC="127.0.0.1:$SC_PORT"
TOPIC="events"
SC_PID=""; A_PID=""; B_PID=""; C_PID=""
cleanup() {
  for pid in "$C_PID" "$B_PID" "$A_PID" "$SC_PID"; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
    [ -n "$pid" ] && wait "$pid" 2>/dev/null || true
  done
}
trap 'cleanup; rm -rf "$WORK"' EXIT

fail() { echo "E2E-P11-ASSETS FAIL: $*" >&2; exit 1; }
pass() { echo "E2E-P11-ASSETS PASS: $*"; }

for port in "$SC_PORT" "$A_PORT" "$B_PORT" "$C_PORT"; do
  if lsof -i ":$port" -sTCP:LISTEN > /dev/null 2>&1; then
    echo "E2E-P11-ASSETS FAIL: port $port is already in use (stale process?)" >&2
    exit 1
  fi
done

wait_listen() { # $1 = port
  for _ in $(seq 1 60); do
    lsof -i ":$1" -sTCP:LISTEN > /dev/null 2>&1 && return 0
    sleep 0.1
  done
  return 1
}

start_sc() {
  "$EXE" sc --listen "$SC" --data-dir "$WORK/sc" >> "$WORK/sc.log" 2>&1 &
  echo $!
}

start_spu() { # $1 = name, $2 = port
  "$EXE" spu --id "$1" --listen "127.0.0.1:$2" --data-dir "$WORK/$1" --sc "$SC" \
    > "$WORK/$1.log" 2>&1 &
  echo $!
}

leader_of() { # $1 = partition
  "$EXE" cluster leader --topic "$TOPIC" --partition "$1" --remote "$SC" 2>/dev/null || true
}

publish() { # $1 = name, $2 = expr, $3 = functions (optional)
  python3 - "$WORK/spec.json" "$1" "$2" "${3:-}" "$WORK/in.txt" "$TOPIC" <<'PY'
import json, sys
out, name, expr, functions, path, topic = sys.argv[1:7]
transform = {"type": "expr", "expr": expr}
if functions:
    transform["functions"] = functions
doc = {
    "apiVersion": "moonflux.io/v1alpha1",
    "kind": "Pipeline",
    "metadata": {"name": name},
    "spec": {
        "source": {"type": "file", "path": path},
        "transforms": [transform],
        "topic": {"name": topic},
        "sink": {"type": "stdout"},
    },
}
open(out, "w").write(json.dumps(doc, indent=2))
PY
  "$EXE" pipeline apply -f "$WORK/spec.json" --remote "$SC"
}

adoptions() { # $1 = node name -> how many times it adopted a revision
  grep -c "cluster pipeline revision" "$WORK/$1.log" || true
}

# ---- cluster up ---------------------------------------------------------
mkdir -p "$WORK/sc" "$WORK/spu-a" "$WORK/spu-b"
printf 'alpha\nbeta\n' > "$WORK/in.txt"
SC_PID="$(start_sc)"
wait_listen "$SC_PORT" || { cat "$WORK/sc.log"; fail "sc did not start"; }
A_PID="$(start_spu spu-a "$A_PORT")"
B_PID="$(start_spu spu-b "$B_PORT")"
wait_listen "$A_PORT" || fail "spu-a did not start"
wait_listen "$B_PORT" || fail "spu-b did not start"
"$EXE" topic create --name "$TOPIC" --partitions 1 --replication-factor 2 --remote "$SC" > /dev/null \
  || fail "topic create failed"
LEADER=""
for _ in $(seq 1 80); do
  LEADER="$(leader_of 0)"
  [ -n "$LEADER" ] && break
  sleep 0.25
done
[ -n "$LEADER" ] || { cat "$WORK/sc.log"; fail "no leader was assigned"; }

# ---- 1. one publish, both nodes -----------------------------------------
"$EXE" pipeline apply -f "$WORK/spec.json" --remote "$SC" > /dev/null 2>&1 || true
publish cluster-demo 'upper(value)' > /dev/null || fail "the publish failed"
ADOPTED=""
for _ in $(seq 1 60); do
  if grep -q "cluster pipeline revision 1 adopted" "$WORK/spu-a.log" &&
    grep -q "cluster pipeline revision 1 adopted" "$WORK/spu-b.log"; then
    ADOPTED=yes
    break
  fi
  sleep 0.25
done
[ -n "$ADOPTED" ] || {
  cat "$WORK/spu-a.log" "$WORK/spu-b.log"
  fail "the nodes did not adopt the published pipeline"
}
pass "one publish at the control plane; both data nodes adopted revision 1"

"$EXE" produce --topic "$TOPIC" --partition 0 --file "$WORK/in.txt" --remote "$LEADER" > /dev/null \
  || fail "produce failed"
"$EXE" consume --topic "$TOPIC" --partition 0 --remote "$LEADER" | cut -f4 > "$WORK/out.txt"
printf 'ALPHA\nBETA\n' > "$WORK/want.txt"
diff -u "$WORK/want.txt" "$WORK/out.txt" || { cat "$WORK/out.txt"; fail "the pulled pipeline did not run"; }
pass "the pulled pipeline runs on the data path (upper applied)"

# ---- 2. fetched when the revision moves, not every heartbeat ------------
A_ADOPT="$(adoptions spu-a)"
sleep 3
A_ADOPT_LATER="$(adoptions spu-a)"
[ "$A_ADOPT" = "$A_ADOPT_LATER" ] \
  || { grep "cluster pipeline revision" "$WORK/spu-a.log"; fail "the node re-adopted without a new revision"; }
pass "revision 1 was adopted once; heartbeats carried it without re-fetching ($A_ADOPT adoption(s) in 3s)"

# ---- 5. a function set published only at the control plane -------------
cat > "$WORK/fns.json" <<'JSON'
{"name":"textkit","version":1,"functions":[{"name":"shout","params":["x"],"body":"upper(x) + \"!\""}]}
JSON
"$EXE" function-set create --file "$WORK/fns.json" --remote "$SC" > /dev/null \
  || fail "the function set could not be created at the control plane"
publish fn-demo 'shout(value)' textkit > /dev/null || fail "the second publish failed"
PULLED=""
for _ in $(seq 1 80); do
  if grep -q "pulled function set textkit" "$WORK/spu-a.log" &&
    grep -q "pulled function set textkit" "$WORK/spu-b.log" &&
    grep -q "cluster pipeline revision 2 adopted" "$WORK/spu-a.log" &&
    grep -q "cluster pipeline revision 2 adopted" "$WORK/spu-b.log"; then
    PULLED=yes
    break
  fi
  sleep 0.25
done
[ -n "$PULLED" ] || {
  cat "$WORK/spu-a.log" "$WORK/spu-b.log"
  fail "the nodes did not pull the function set"
}
"$EXE" consume --topic "$TOPIC" --partition 0 --remote "$LEADER" | cut -f4 > "$WORK/out2.txt"
printf 'ALPHA!\nBETA!\n' > "$WORK/want2.txt"
diff -u "$WORK/want2.txt" "$WORK/out2.txt" \
  || { cat "$WORK/out2.txt"; fail "the pulled function set did not run"; }
pass "a function set created only at the control plane reached both nodes and runs there"

# ---- 3. a node that joins later ----------------------------------------
C_PID="$(start_spu spu-c "$C_PORT")"
wait_listen "$C_PORT" || fail "spu-c did not start"
LATE=""
for _ in $(seq 1 80); do
  if grep -q "cluster pipeline revision 2 adopted" "$WORK/spu-c.log" &&
    grep -q "pulled function set textkit" "$WORK/spu-c.log"; then
    LATE=yes
    break
  fi
  sleep 0.25
done
[ -n "$LATE" ] || { cat "$WORK/spu-c.log"; fail "a late node did not adopt the current revision"; }
pass "a node that joined later adopted revision 2 and pulled the set on its own"

# ---- 4. the control plane goes away ------------------------------------
kill "$SC_PID" 2>/dev/null || true; wait "$SC_PID" 2>/dev/null || true
SC_PID=""
sleep 2
# no new write here: the property under test is that the *read path*
# still serves the pipeline the node already has
"$EXE" consume --topic "$TOPIC" --partition 0 --remote "$LEADER" | cut -f4 > "$WORK/out3.txt" \
  || fail "the holder stopped serving when the control plane went away"
diff -u "$WORK/want2.txt" "$WORK/out3.txt" || fail "the pipeline changed when the control plane went away"
UNREACHABLE_LINES=$(grep -c "control plane 127.0.0.1:$SC_PORT unreachable" "$WORK/spu-a.log" || true)
[ "$UNREACHABLE_LINES" -le 2 ] \
  || { grep "unreachable" "$WORK/spu-a.log" | head -3; fail "the unreachable warning repeated $UNREACHABLE_LINES times"; }
pass "with the control plane gone the nodes keep serving (and say so once)"

# ---- 6. a regressed control plane does not drag nodes back -------------
# replace the stored document with revision 1 and restart: a node that
# already runs revision 2 must keep it
python3 - "$WORK/sc/pipeline.json" <<'PY'
import json, sys
path = sys.argv[1]
doc = json.load(open(path))
doc["revision"] = 1
json.dump(doc, open(path, "w"), indent=2)
PY
SC_PID="$(start_sc)"
wait_listen "$SC_PORT" || fail "sc did not restart"
sleep 3
python3 - "$WORK/spu-a/topology.json" <<'PY' || fail "a node went backwards"
import json, sys
doc = json.load(open(sys.argv[1]))
assert doc.get("cluster_revision") == 2, f"node revision regressed to {doc.get('cluster_revision')}"
PY
pass "a control plane that regressed to revision 1 did not drag the nodes back"

echo "E2E-P11-ASSETS: all green"
