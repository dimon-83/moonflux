#!/bin/bash
# P12 gate: the security face — authentication, authorization, transport.
#
# Every leg here is about a *refusal*, because that is what a security
# face is: the assertions are on what must not happen, and each one names
# the check that stops it.
#
#   1. no auth configured: behavior is exactly what it was, and the
#      process says so at startup (a silent security mode is the bug)
#   2. no credential: refused before any command is served
#   3. a wrong token: refused, and the token is never logged
#   4. read-only: may consume and read watermarks, may not produce,
#      delete a topic, or rewrite the cluster's function sets
#   5. a *client* identity may not issue node commands (forged REGISTER /
#      SYNC_ACK) — the structural block on forging a high watermark
#   6. TLS: a wrong CA, no client certificate, or a plaintext client is
#      refused; the right CA works and the server survives the probes
#   7. under TLS *and* auth, replication is still byte-identical — the
#      security face must not change what is replicated
#
# The forged-node legs use scripts/mfs_probe.py, an independent client
# that writes MFS frames itself: the assertion then is about the server's
# authorization, not about what the moonflux CLI is willing to send.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# The debug build is what `moon build --target native` (and `moon test`)
# produce, so it is the artifact every gate here means to test. A release
# binary is only a fallback: preferring it once meant a gate silently
# tested a build from an earlier session.
EXE="${MOONFLUX_EXE:-$ROOT/_build/native/debug/build/apps/cli/cli.exe}"
[ -x "$EXE" ] || EXE="$ROOT/_build/native/release/build/apps/cli/cli.exe"
[ -x "$EXE" ] || { echo "cli executable not found; run: moon build --target native" >&2; exit 1; }
PROBE="$ROOT/scripts/mfs_probe.py"

WORK="$(mktemp -d /tmp/moonflux-p12-security.XXXXXX)"
SC_PORT="${MOONFLUX_P12_SC_PORT:-19751}"
A_PORT="${MOONFLUX_P12_SPU_A_PORT:-19752}"
B_PORT="${MOONFLUX_P12_SPU_B_PORT:-19753}"
PLAIN_PORT="${MOONFLUX_P12_PLAIN_PORT:-19754}"
PROBE_SC_PORT="${MOONFLUX_P12_PROBE_SC_PORT:-19755}"
TOPIC="${MOONFLUX_P12_TOPIC:-events}"
SC_PID=""; A_PID=""; B_PID=""; PLAIN_PID=""
CLEANUP_PIDS=()
cleanup() {
  for pid in "${CLEANUP_PIDS[@]}"; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
    [ -n "$pid" ] && wait "$pid" 2>/dev/null || true
  done
}
trap 'cleanup; if [ "${MOONFLUX_KEEP:-0}" = "1" ]; then echo "keeping $WORK"; else rm -rf "$WORK"; fi' EXIT

fail() { echo "E2E-P12-SECURITY FAIL: $*" >&2; exit 1; }
pass() { echo "E2E-P12-SECURITY PASS: $*"; }
skip() { echo "E2E-P12-SECURITY SKIP: $*"; }
note() { echo "  · $*"; }

wait_listen() { # $1 = port
  for _ in $(seq 1 60); do
    lsof -i ":$1" -sTCP:LISTEN > /dev/null 2>&1 && return 0
    sleep 0.1
  done
  return 1
}

wait_log() { # $1 = file, $2 = extended regex, $3 = seconds (default 10)
  # A server announces its modes right after binding, and this gate learns
  # the server is up from the PORT — which opens before the announcement
  # is written. On CI's cold macOS runner that gap (auth table load,
  # OpenSSL dlopen, certificate parse) outlived a single grep: the gate
  # failed with a log holding only the "listening" line, captured 0.3 ms
  # after it appeared. Assert that the announcement happens, not that it
  # has already landed at the instant the socket accepts.
  local file=$1 pattern=$2 tries=$(( ${3:-10} * 20 ))
  while [ "$tries" -gt 0 ]; do
    grep -qE "$pattern" "$file" 2>/dev/null && return 0
    sleep 0.05
    tries=$((tries - 1))
  done
  return 1
}

# Flags travel as arrays: an unquoted "$VAR" holding several flags is a
# single argument in some shells (this project's own smoke testing hit
# exactly that — the client sent plaintext and it looked like a TLS bug).

# ---- certificates -------------------------------------------------------
if ! command -v openssl > /dev/null 2>&1; then
  skip "openssl not found: TLS legs are skipped, auth legs still run"
  TLS_AVAILABLE=""
else
  TLS_AVAILABLE=yes
fi

gen_certs() {
  local ca_dir="$1"
  openssl req -x509 -newkey rsa:2048 -nodes -keyout "$ca_dir/ca.key" \
    -out "$ca_dir/ca.pem" -days 2 -subj "/CN=moonflux-p12-ca" 2>/dev/null
  for name in sc spu-a spu-b client; do
    openssl req -newkey rsa:2048 -nodes -keyout "$ca_dir/$name.key" \
      -out "$ca_dir/$name.csr" -subj "/CN=$name" 2>/dev/null
    printf 'subjectAltName=DNS:%s,DNS:localhost,IP:127.0.0.1\n' "$name" \
      > "$ca_dir/$name.ext"
    openssl x509 -req -in "$ca_dir/$name.csr" -CA "$ca_dir/ca.pem" \
      -CAkey "$ca_dir/ca.key" -CAcreateserial -out "$ca_dir/$name.pem" \
      -days 2 -extfile "$ca_dir/$name.ext" 2>/dev/null
  done
  # a second, unrelated CA: the client that must be refused
  openssl req -x509 -newkey rsa:2048 -nodes -keyout "$ca_dir/rogue-ca.key" \
    -out "$ca_dir/rogue-ca.pem" -days 2 -subj "/CN=rogue-ca" 2>/dev/null
  openssl req -newkey rsa:2048 -nodes -keyout "$ca_dir/rogue.key" \
    -out "$ca_dir/rogue.csr" -subj "/CN=rogue" 2>/dev/null
  printf 'subjectAltName=DNS:localhost,IP:127.0.0.1\n' > "$ca_dir/rogue.ext"
  openssl x509 -req -in "$ca_dir/rogue.csr" -CA "$ca_dir/rogue-ca.pem" \
    -CAkey "$ca_dir/rogue-ca.key" -CAcreateserial -out "$ca_dir/rogue.pem" \
    -days 2 -extfile "$ca_dir/rogue.ext" 2>/dev/null
}

# ---- 1. no auth configured: unchanged, and loudly so --------------------
mkdir -p "$WORK/plain"
"$EXE" serve --listen "127.0.0.1:$PLAIN_PORT" --data-dir "$WORK/plain" \
  > "$WORK/plain.log" 2>&1 &
PLAIN_PID=$!
CLEANUP_PIDS+=("$PLAIN_PID")
wait_listen "$PLAIN_PORT" || { cat "$WORK/plain.log"; fail "plain serve did not start"; }
wait_log "$WORK/plain.log" "authentication DISABLED" \
  || { cat "$WORK/plain.log"; fail "an unauthenticated broker did not announce it"; }
pass "1. authentication off is announced at startup: $(grep -o 'authentication DISABLED.*' "$WORK/plain.log" | head -1)"
printf 'plain-1\nplain-2\n' > "$WORK/plain-in.txt"
"$EXE" produce --topic "$TOPIC" --file "$WORK/plain-in.txt" --remote "127.0.0.1:$PLAIN_PORT" \
  > /dev/null || fail "plain produce failed: without auth.json nothing may change"
"$EXE" consume --topic "$TOPIC" --remote "127.0.0.1:$PLAIN_PORT" --max-records 5 \
  | grep -q "plain-2" || fail "plain consume failed: without auth.json nothing may change"
pass "1b. without auth.json, produce/consume behave exactly as before"
kill "$PLAIN_PID" 2>/dev/null || true; wait "$PLAIN_PID" 2>/dev/null || true

# ---- secured cluster ----------------------------------------------------
if [ -n "$TLS_AVAILABLE" ]; then
  gen_certs "$WORK" || fail "certificate generation failed"
fi

cat > "$WORK/auth.json" <<'JSON'
{"credentials":[
  {"name":"root","token":"root-token-123456","role":"root"},
  {"name":"node-a","token":"spu-a-node-token","role":"node"},
  {"name":"spu-b","token":"spu-b-node-token","role":"node"},
  {"name":"alice","token":"alice-secret-1234","role":"read-write"},
  {"name":"bob","token":"bob-secret-123456","role":"read-only"},
  {"name":"carol","token":"carol-secret-12345","role":"read-write",
   "grants":[{"topic":"orders","read":true,"write":true}]},
  {"name":"dave","token":"dave-secret-123456","role":"read-only",
   "grants":[{"topic":"orders","read":true,"write":true}]}
]}
JSON
for d in sc spu-a spu-b; do
  mkdir -p "$WORK/$d"
  cp "$WORK/auth.json" "$WORK/$d/auth.json"
done

# The client side of a mutual-TLS cluster: the trust anchor *and* this
# process's own certificate (the listener requires one). The node
# processes get theirs per node in start_spu.
CLIENT_TLS=()
if [ -n "$TLS_AVAILABLE" ]; then
  CLIENT_TLS=(
    --tls-ca "$WORK/ca.pem"
    --tls-cert "$WORK/client.pem"
    --tls-key "$WORK/client.key"
  )
fi

"$EXE" sc --listen "127.0.0.1:$SC_PORT" --data-dir "$WORK/sc" \
  ${TLS_AVAILABLE:+--tls-cert "$WORK/sc.pem" --tls-key "$WORK/sc.key" --tls-ca "$WORK/ca.pem" --tls-require-client} \
  > "$WORK/sc.log" 2>&1 &
SC_PID=$!; CLEANUP_PIDS+=("$SC_PID")
wait_listen "$SC_PORT" || { cat "$WORK/sc.log"; fail "sc did not start"; }
wait_log "$WORK/sc.log" "authentication ENABLED" 15 || { cat "$WORK/sc.log"; fail "the control plane did not announce auth"; }

start_spu() { # $1 = id, $2 = port, $3 = token
  "$EXE" spu --id "$1" --listen "127.0.0.1:$2" --data-dir "$WORK/$1" \
    --sc "127.0.0.1:$SC_PORT" --token "$3" \
    ${TLS_AVAILABLE:+--tls-cert "$WORK/$1.pem" --tls-key "$WORK/$1.key" --tls-ca "$WORK/ca.pem" --tls-require-client} \
    > "$WORK/$1.log" 2>&1 &
  echo $!
}
A_PID="$(start_spu spu-a "$A_PORT" spu-a-node-token)"; CLEANUP_PIDS+=("$A_PID")
B_PID="$(start_spu spu-b "$B_PORT" spu-b-node-token)"; CLEANUP_PIDS+=("$B_PID")
wait_listen "$A_PORT" || { cat "$WORK/spu-a.log"; fail "spu-a did not start"; }
wait_listen "$B_PORT" || { cat "$WORK/spu-b.log"; fail "spu-b did not start"; }

# the control-plane client flags (credential + transport) for the CLI
ROOT_FLAGS=(--token root-token-123456 "${CLIENT_TLS[@]}")

# ---- pipeline + topic (as root) ----------------------------------------
cat > "$WORK/spec.json" <<JSON
{
  "apiVersion": "moonflux.io/v1alpha1",
  "kind": "Pipeline",
  "metadata": { "name": "secured" },
  "spec": {
    "source": { "type": "file", "path": "$WORK/in.txt" },
    "transforms": [],
    "topic": { "name": "$TOPIC" },
    "sink": { "type": "stdout" }
  }
}
JSON
printf 'seed\n' > "$WORK/in.txt"
"$EXE" pipeline apply -f "$WORK/spec.json" --remote "127.0.0.1:$SC_PORT" "${ROOT_FLAGS[@]}" \
  > /dev/null || { cat "$WORK/sc.log"; fail "root could not apply the cluster pipeline"; }
"$EXE" topic create --name "$TOPIC" --partitions 3 --replication-factor 2 \
  --remote "127.0.0.1:$SC_PORT" "${ROOT_FLAGS[@]}" > /dev/null \
  || fail "root could not create the topic"

# ---- 2. no credential is refused ---------------------------------------
OUT="$("$EXE" topic list --remote "127.0.0.1:$SC_PORT" "${CLIENT_TLS[@]}" 2>&1 || true)"
printf '%s' "$OUT" | grep -qE "code[ =]9" \
  || fail "an unauthenticated client was not refused with ERR_AUTH_REQUIRED: $OUT"
pass "2. no credential: $(printf '%s' "$OUT" | sed 's/^error: //')"

# ---- 3. a wrong token is refused (and never logged) --------------------
OUT="$("$EXE" topic list --remote "127.0.0.1:$SC_PORT" --token wrong-token-111111 \
  "${CLIENT_TLS[@]}" 2>&1 || true)"
printf '%s' "$OUT" | grep -qE "code[ =]9" \
  || fail "a bad token was not refused: $OUT"
pass "3. wrong token: $(printf '%s' "$OUT" | sed 's/^error: //')"
for log in "$WORK/sc.log" "$WORK/spu-a.log"; do
  if grep -q "alice-secret-1234\|spu-a-node-token\|root-token-123456" "$log"; then
    fail "a credential was written to $(basename "$log")"
  fi
done
pass "3b. no credential appears in any log"

# ---- 4. read-only may read and may not write ---------------------------
BOB_FLAGS=(--token bob-secret-123456 "${CLIENT_TLS[@]}")
ALICE_FLAGS=(--token alice-secret-1234 "${CLIENT_TLS[@]}")

# wait for placement, then produce as alice so bob has something to read
LEADER=""
for _ in $(seq 1 80); do
  LEADER="$("$EXE" cluster leader --topic "$TOPIC" --partition 0 --remote "127.0.0.1:$SC_PORT" \
    "${ROOT_FLAGS[@]}" 2>/dev/null || true)"
  [ -n "$LEADER" ] && break
  sleep 0.25
done
[ -n "$LEADER" ] || { cat "$WORK/sc.log"; fail "no leader was elected for $TOPIC[0]"; }
printf 'ro-1\n' > "$WORK/ro.txt"
"$EXE" produce --topic "$TOPIC" --file "$WORK/ro.txt" --remote "$LEADER" "${ALICE_FLAGS[@]}" \
  > /dev/null || fail "read-write could not produce"

OUT="$("$EXE" consume --topic "$TOPIC" --remote "$LEADER" --max-records 5 "${BOB_FLAGS[@]}" 2>&1 || true)"
printf '%s' "$OUT" | grep -q "ro-1" \
  || fail "read-only could not consume: $OUT"
pass "4a. read-only consumes ($(printf '%s\n' "$OUT" | wc -l | tr -d ' ') record(s))"

OUT="$("$EXE" produce --topic "$TOPIC" --file "$WORK/ro.txt" --remote "$LEADER" "${BOB_FLAGS[@]}" 2>&1 || true)"
printf '%s' "$OUT" | grep -qE "code[ =]10" \
  || fail "read-only was allowed to produce: $OUT"
note "read-only produce: $(printf '%s' "$OUT" | sed 's/^error: //')"

OUT="$("$EXE" topic delete --name "$TOPIC" --remote "127.0.0.1:$SC_PORT" "${BOB_FLAGS[@]}" 2>&1 || true)"
printf '%s' "$OUT" | grep -qE "code[ =]10" \
  || fail "read-only was allowed to delete a topic: $OUT"
note "read-only topic delete: $(printf '%s' "$OUT" | sed 's/^error: //')"

cat > "$WORK/fns.json" <<'JSON'
{"name":"greetings","functions":[{"name":"twice","params":["x"],"body":"x + x"}]}
JSON
OUT="$("$EXE" function-set create --file "$WORK/fns.json" --remote "127.0.0.1:$SC_PORT" \
  "${BOB_FLAGS[@]}" 2>&1 || true)"
printf '%s' "$OUT" | grep -qE "code[ =]10" \
  || fail "read-only was allowed to rewrite a function set: $OUT"
pass "4b. read-only is refused every write (produce, topic delete, function set)"

# ---- 5. a client identity may not issue node commands ------------------
# Two forged node commands, from an independent client, with a perfectly
# valid *client* credential. The assertion is on code 10 (ERR_FORBIDDEN)
# rather than "some error": the permission check runs before the payload
# is parsed, so a refusal proves the door, and a parse error here would
# mean the door had been opened.
probe() { # $1 = addr, rest = probe args
  local addr="$1"; shift
  python3 "$PROBE" "$addr" "$@" 2>&1 || true
}

PROBE_TLS=(--tls-ca "$WORK/ca.pem" --tls-cert "$WORK/client.pem" --tls-key "$WORK/client.key")
if [ -z "$TLS_AVAILABLE" ]; then
  PROBE_TLS=()
fi

OUT="$(probe "127.0.0.1:$SC_PORT" --cmd 7 --payload "node:fake:spu:0:127.0.0.1:19999" \
  --token alice-secret-1234 "${PROBE_TLS[@]}")"
printf '%s' "$OUT" | grep -q "REFUSED 10" \
  || fail "a client credential was allowed to REGISTER a phantom node: $OUT"
pass "5a. forged REGISTER refused: $(printf '%s' "$OUT" | sed 's/REFUSED /code /')"

OUT="$(probe "127.0.0.1:$A_PORT" --cmd 12 --payload "00" --token alice-secret-1234 "${PROBE_TLS[@]}")"
printf '%s' "$OUT" | grep -q "REFUSED 10" \
  || fail "a client credential was allowed to send SYNC_ACK: $OUT"
pass "5b. forged SYNC_ACK refused (the high watermark cannot be moved by a client)"

# The boundary is a role, not a wall: the same REGISTER with a node
# credential is served, which is what makes the refusal above a statement
# about *authorization* rather than about a broken frame. It runs against
# a second control plane on purpose — an accepted registration really
# does enter the table, and placement would then wait forever on a
# replica that never reports. That consequence is the argument for
# keeping node credentials away from clients.
mkdir -p "$WORK/probe-sc"
cp "$WORK/auth.json" "$WORK/probe-sc/auth.json"
"$EXE" sc --listen "127.0.0.1:$PROBE_SC_PORT" --data-dir "$WORK/probe-sc" \
  ${TLS_AVAILABLE:+--tls-cert "$WORK/sc.pem" --tls-key "$WORK/sc.key" --tls-ca "$WORK/ca.pem" --tls-require-client} \
  > "$WORK/probe-sc.log" 2>&1 &
PROBE_SC_PID=$!; CLEANUP_PIDS+=("$PROBE_SC_PID")
wait_listen "$PROBE_SC_PORT" || { cat "$WORK/probe-sc.log"; fail "the probe control plane did not start"; }
OUT="$(probe "127.0.0.1:$PROBE_SC_PORT" --cmd 7 --payload "node:real-node:spu:0:127.0.0.1:19998" \
  --token spu-a-node-token "${PROBE_TLS[@]}")"
printf '%s' "$OUT" | grep -q "ACCEPTED" \
  || fail "a node credential could not register (the refusal above proves nothing then): $OUT"
pass "5c. the same REGISTER with a node credential is accepted (role, not wall)"

# ---- 6. TLS refusals, and the server survives them ---------------------
if [ -n "$TLS_AVAILABLE" ]; then
  OUT="$("$EXE" topic list --remote "127.0.0.1:$SC_PORT" --token root-token-123456 2>&1 || true)"
  printf '%s' "$OUT" | grep -q "error" \
    || fail "a plaintext client was served by a TLS listener: $OUT"
  note "plaintext against the TLS port: $(printf '%s' "$OUT" | sed 's/^error: //')"

  OUT="$("$EXE" topic list --remote "127.0.0.1:$SC_PORT" --token root-token-123456 \
    --tls-ca "$WORK/rogue-ca.pem" --tls-cert "$WORK/rogue.pem" --tls-key "$WORK/rogue.key" 2>&1 || true)"
  printf '%s' "$OUT" | grep -qE "certificate verify failed|code 20|verify" \
    || fail "an untrusted CA was accepted: $OUT"
  pass "6a. a certificate from another CA is refused: $(printf '%s' "$OUT" | sed 's/^error: //' | cut -c1-120)"

  OUT="$("$EXE" topic list --remote "127.0.0.1:$SC_PORT" --token root-token-123456 \
    --tls-ca "$WORK/ca.pem" 2>&1 || true)"
  printf '%s' "$OUT" | grep -q "error" \
    || fail "a client with no certificate was served on a mutual-TLS port: $OUT"
  pass "6b. no client certificate is refused where one is required"

  kill -0 "$SC_PID" 2>/dev/null || fail "the control plane died from the TLS probes"
  OUT="$("$EXE" topic list --remote "127.0.0.1:$SC_PORT" "${ROOT_FLAGS[@]}" 2>&1 || true)"
  printf '%s' "$OUT" | grep -q "$TOPIC" \
    || fail "the control plane stopped serving after the probes: $OUT"
  pass "6c. the right CA works, and the server survived the probes"
fi

# ---- 7. replication is byte-identical under TLS + auth -----------------
# The TLS probes in leg 6 cost the control plane a few handshake timeouts,
# and a node that misses its beat while the control plane is busy is
# declared offline and its partitions re-elected (see the ticket: the
# control plane serves one connection at a time). So leaders are waited
# for, not assumed — the same stance the P7 gate takes.
leader_of() { # $1 = partition
  for _ in $(seq 1 80); do
    local leader
    leader="$("$EXE" cluster leader --topic "$TOPIC" --partition "$1" \
      --remote "127.0.0.1:$SC_PORT" "${ROOT_FLAGS[@]}" 2>/dev/null || true)"
    if [ -n "$leader" ]; then printf '%s' "$leader"; return 0; fi
    sleep 0.25
  done
  return 1
}

for p in 0 1 2; do
  printf 'p%d-r1\np%d-r2\n' "$p" "$p" > "$WORK/in-$p.txt"
  PLACE_LEADER="$(leader_of "$p")" || { cat "$WORK/sc.log"; fail "no leader for $TOPIC[$p]"; }
  PRODUCED=""
  for _ in $(seq 1 40); do
    if "$EXE" produce --topic "$TOPIC" --partition "$p" --file "$WORK/in-$p.txt" \
      --remote "$PLACE_LEADER" "${ALICE_FLAGS[@]}" > /dev/null 2>&1; then
      PRODUCED=yes; break
    fi
    PLACE_LEADER="$(leader_of "$p")" || break
    sleep 0.25
  done
  [ -n "$PRODUCED" ] || fail "produce to $TOPIC[$p] failed"
done
# "replicated" means every partition's high watermark caught up with its
# log end, and every partition has the records this leg wrote — not that
# the numbers equal one particular value (leg 4 already wrote to
# partition 0, and a hard-coded 2 would be asserting the order the legs
# happen to run in).
count_settled() { # stdin = cluster status; prints how many partitions are caught up
  # "hw=?" (leader unreachable at query time) must NOT count as settled:
  # awk compares "?" and "2" as strings and "?" sorts higher — the gate
  # would pass while the partition never replicated
  awk '
    /\[[0-9]+\] leader=/ {
      hw=""; leo="";
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^hw=[0-9]+$/) { sub("hw=", "", $i); hw = $i }
        if ($i ~ /^leo=[0-9]+$/) { sub("leo=", "", $i); leo = $i }
      }
      if (hw != "" && hw == leo && hw + 0 >= 2) n++
    }
    END { print n + 0 }'
}
SETTLED=""
for _ in $(seq 1 80); do
  STATUS="$("$EXE" cluster status --remote "127.0.0.1:$SC_PORT" "${ROOT_FLAGS[@]}" 2>/dev/null || true)"
  [ "$(printf '%s\n' "$STATUS" | count_settled)" = "3" ] && { SETTLED=yes; break; }
  sleep 0.25
done
[ -n "$SETTLED" ] || { printf '%s\n' "$STATUS"; fail "partitions did not replicate (hw != leo on some partition)"; }
STATUS="$( "$EXE" cluster status --remote "127.0.0.1:$SC_PORT" "${ROOT_FLAGS[@]}" 2>/dev/null || true )"
OFFSETS="$( "$EXE" cluster offsets --topic "$TOPIC" --partition 0 --remote "$LEADER" 2>/dev/null || true )"
for p in 0 1 2; do
  A="$WORK/spu-a/topics/$TOPIC/partition-$p/00000000000000000000.log"
  B="$WORK/spu-b/topics/$TOPIC/partition-$p/00000000000000000000.log"
  [ -f "$A" ] || fail "spu-a has no segment for partition $p"
  [ -f "$B" ] || fail "spu-b has no segment for partition $p"
  cmp -s "$A" "$B" \
    || fail "replication under TLS is not byte-identical for partition $p (status: $STATUS; p0 offsets: $OFFSETS; A=$(stat -f%z "$A" 2>/dev/null) B=$(stat -f%z "$B" 2>/dev/null))"
done
pass "7. replication under TLS + auth is byte-identical on all 3 partitions"

# ---- 8. per-topic grants: allowed here, refused there (P21) -----------
# orders must be declared and placed before a cluster node will host it
"$EXE" topic create --name orders --remote "127.0.0.1:$SC_PORT" "${ROOT_FLAGS[@]}" > /dev/null \
  || fail "topic create for the ACL legs failed"
ORDERS_LEADER=""
for _ in $(seq 1 40); do
  OUT="$("$EXE" cluster leader --topic orders --remote "127.0.0.1:$SC_PORT" "${ROOT_FLAGS[@]}" 2>/dev/null || true)"
  case "$OUT" in 127.0.0.1:*) ORDERS_LEADER="$OUT"; break ;; esac
  sleep 0.25
done
[ -n "$ORDERS_LEADER" ] || fail "orders was never placed"
printf 'order-1\n' > "$WORK/orders.txt"
OUT=""
for _ in $(seq 1 40); do
  OUT="$("$EXE" produce --topic orders --file "$WORK/orders.txt" --remote "$ORDERS_LEADER" \
    --token carol-secret-12345 "${CLIENT_TLS[@]}" 2>&1 || true)"
  printf '%s' "$OUT" | grep -q "offsets 0" && break
  sleep 0.25
done
[[ "$OUT" == *"offsets 0"* ]] \
  || fail "carol could not produce to her granted topic: $OUT"
OUT="$("$EXE" consume --topic orders --remote "$ORDERS_LEADER" --max-records 5 \
  --token carol-secret-12345 "${CLIENT_TLS[@]}" 2>&1 || true)"
[[ "$OUT" == *"order-1"* ]] \
  || fail "carol could not read her granted topic: $OUT"
OUT="$("$EXE" produce --topic "$TOPIC" --file "$WORK/ro.txt" --remote "$LEADER" \
  --token carol-secret-12345 "${CLIENT_TLS[@]}" 2>&1 || true)"
[[ "$OUT" =~ code[[:space:]=]+10 ]] \
  || fail "carol was allowed into an ungranted topic: $OUT"
[[ "$OUT" == *"may not write topic"* ]] \
  || fail "the grant refusal does not name the topic and user: $OUT"
OUT="$("$EXE" consume --topic "$TOPIC" --remote "$LEADER" --max-records 5 \
  --token carol-secret-12345 "${CLIENT_TLS[@]}" 2>&1 || true)"
[[ "$OUT" =~ code[[:space:]=]+10 ]] \
  || fail "carol was allowed to read an ungranted topic: $OUT"
pass "8. per-topic grants: carol works orders, and events refuses her by name"

# ---- 9. grants narrow; the role table still governs kind --------------
OUT="$("$EXE" produce --topic orders --file "$WORK/orders.txt" --remote "$ORDERS_LEADER" \
  --token dave-secret-123456 "${CLIENT_TLS[@]}" 2>&1 || true)"
[[ "$OUT" =~ code[[:space:]=]+10 ]] \
  || fail "a read-only role was widened by a write grant: $OUT"
OUT="$("$EXE" consume --topic orders --remote "$ORDERS_LEADER" --max-records 5 \
  --token dave-secret-123456 "${CLIENT_TLS[@]}" 2>&1 || true)"
[[ "$OUT" == *"order-1"* ]] \
  || fail "dave could not read his granted topic: $OUT"
pass "9. grants narrow, never widen: the role table ran first (dave read orders, wrote nothing)"

# ---- 10. the audit log remembers every denial, and no secret ----------
AUDIT_LINES="$(cat "$WORK"/*/audit.log 2>/dev/null | wc -l | tr -d ' ')"
[ "$AUDIT_LINES" -ge 3 ] || fail "audit.log has $AUDIT_LINES lines; denials and auth outcomes must land"
grep -q '"topic":"events"' "$WORK"/*/audit.log 2>/dev/null ||
  fail "carol's ungranted-topic denial is not audited with its topic"
grep -q '"user":"dave","role":"read-only","cmd"' "$WORK"/*/audit.log 2>/dev/null ||
  fail "dave's role-table denial is not audited with his role"
grep -q '"user":"carol","decision":"allow"' "$WORK"/*/audit.log 2>/dev/null ||
  fail "carol's successful authentication is not audited"
if grep -q "carol-secret-12345\|dave-secret-123456\|alice-secret-1234\|bob-secret-123456\|spu-a-node-token\|root-token-123456" \
    "$WORK"/*/audit.log 2>/dev/null; then
  fail "credential material leaked into the audit log"
fi
pass "10. the audit log carries denials and auth outcomes, and no credential material"
pass "P12 security gate: 10 legs green ($([ -n "$TLS_AVAILABLE" ] && echo "TLS + auth" || echo "auth only"))"
