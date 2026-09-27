#!/bin/bash
# P24 gate: rotation without restart.
#
#    1. a serve runs with certificate v1 (signed by CA1) and credential
#       "before" — a client trusting CA1 authenticates with it
#    2. the operator replaces the certificate with v2 (signed by CA2)
#       and the credential table (before -> after) — WITHOUT restarting:
#       after the watcher's beat, a client trusting CA2 handshakes and
#       authenticates as "after"; a client still trusting CA1 is
#       REFUSED (the server presents the new certificate now); token
#       "before" is refused. The serve log carries the reload notes,
#       and the server never went down.
#    3. the control plane rotates the same way (sc, same mechanism)
#    4. authentication enabled without TLS announces the cleartext
#       warning at startup — a silent insecure mode is itself a hole
#
# The mechanism under test is mtime watching (P24): the files are
# replaced on disk, nothing signals the process, and the next check
# (one second cadence) swaps the material.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
EXE="${MOONFLUX_EXE:-$ROOT/_build/native/debug/build/apps/cli/cli.exe}"
[ -x "$EXE" ] || EXE="$ROOT/_build/native/release/build/apps/cli/cli.exe"

WORK="$(mktemp -d /tmp/moonflux-p24-rotation.XXXXXX)"
SERVE_PORT="${MOONFLUX_P24_SERVE_PORT:-19711}"
SC_PORT="${MOONFLUX_P24_SC_PORT:-19712}"

PIDS=()
cleanup() {
  for pid in "${PIDS[@]:-}"; do kill "$pid" 2>/dev/null || true; done
  pkill -f "moonflux-p24-rotation" 2>/dev/null || true
}
trap 'cleanup; if [ "${MOONFLUX_KEEP:-0}" = "1" ]; then echo "keeping $WORK"; else rm -rf "$WORK"; fi' EXIT

fail() { echo "E2E-P24-ROTATION FAIL: $*" >&2; exit 1; }
pass() { echo "E2E-P24-ROTATION PASS: $*"; }
wait_listen() {
  for _ in $(seq 1 60); do
    lsof -i ":$1" -sTCP:LISTEN > /dev/null 2>&1 && return 0
    sleep 0.1
  done
  return 1
}

wait_log() { # $1 = file, $2 = extended regex, $3 = seconds (default 10)
  # Startup announcements land just after the port opens; a single
  # immediate grep is a race the dev machine wins and a cold CI runner
  # loses (see the p12/p13 failures of 2026-09-27).
  local file=$1 pattern=$2 tries=$(( ${3:-10} * 20 ))
  while [ "$tries" -gt 0 ]; do
    grep -qE "$pattern" "$file" 2>/dev/null && return 0
    sleep 0.05
    tries=$((tries - 1))
  done
  return 1
}

gen_cert() { # $1 = ca prefix, $2 = leaf name -> CA + signed server cert
  openssl req -x509 -newkey rsa:2048 -nodes -keyout "$WORK/$1-ca.key" \
    -out "$WORK/$1-ca.pem" -days 2 -subj "/CN=p24-$1" 2>/dev/null
  openssl req -newkey rsa:2048 -nodes -keyout "$WORK/$2.key" \
    -out "$WORK/$2.csr" -subj "/CN=$2" 2>/dev/null
  printf 'subjectAltName=DNS:localhost,IP:127.0.0.1\n' > "$WORK/$2.ext"
  openssl x509 -req -in "$WORK/$2.csr" -CA "$WORK/$1-ca.pem" \
    -CAkey "$WORK/$1-ca.key" -CAcreateserial -out "$WORK/$2.pem" \
    -days 2 -extfile "$WORK/$2.ext" 2>/dev/null
  [ -s "$WORK/$2.pem" ] || fail "certificate generation failed for $2"
}

pkill -f "moonflux-p24-rotation" 2>/dev/null || true
sleep 1
mkdir -p "$WORK/serve" "$WORK/sc"

# the credential table starts naming "before"; rotation swaps it to
# "after" (both tokens are long enough for the loader's minimum)
write_auth() { # $1 = name
  cat > "$WORK/serve/auth.json" <<JSON
{"credentials":[{"name":"$1","token":"p24-$1-token-123456","role":"read-write"}]}
JSON
}

gen_cert ca1 serve-v1
gen_cert ca2 serve-v2
# the listener's material: same paths the watcher watches
cp "$WORK/serve-v1.pem" "$WORK/serve/server.pem"
cp "$WORK/serve-v1.key" "$WORK/serve/server.key"
write_auth before

"$EXE" serve --data-dir "$WORK/serve" --listen "127.0.0.1:$SERVE_PORT" \
  --tls-cert "$WORK/serve/server.pem" --tls-key "$WORK/serve/server.key" \
  > "$WORK/serve.log" 2>&1 &
SERVE_PID=$!
PIDS+=("$SERVE_PID")
wait_listen "$SERVE_PORT" || { cat "$WORK/serve.log"; fail "serve did not start"; }

# ---- 1. baseline: CA1 trust chain works, credential "before" works ------
printf 'r0\n' > "$WORK/in.txt"
OUT="$("$EXE" produce --topic t --file "$WORK/in.txt" --remote "127.0.0.1:$SERVE_PORT" \
  --tls-ca "$WORK/ca1-ca.pem" --token p24-before-token-123456 2>&1 || true)"
printf '%s' "$OUT" | grep -q "offsets 0" \
  || fail "baseline produce failed under CA1 + credential before: $OUT"
pass "baseline: CA1 client produced with credential before"

# ---- 2. rotate: new cert (CA2) + new credential, no restart --------------
cp "$WORK/serve-v2.pem" "$WORK/serve/server.pem"
cp "$WORK/serve-v2.key" "$WORK/serve/server.key"
write_auth after
sleep 2.5 # the watcher's one-second beat, with slack

# 2a. a client trusting the NEW CA handshakes and authenticates
printf 'r1\n' > "$WORK/in-after.txt"
OUT="$("$EXE" produce --topic t --file "$WORK/in-after.txt" --remote "127.0.0.1:$SERVE_PORT" \
  --tls-ca "$WORK/ca2-ca.pem" --token p24-after-token-123456 2>&1 || true)"
printf '%s' "$OUT" | grep -q "offsets 1..2" \
  || fail "after rotation, a CA2 client could not produce with credential after: $OUT"

# 2b. a client still trusting the OLD CA is refused (server presents v2)
OUT="$("$EXE" produce --topic t --file "$WORK/in.txt" --remote "127.0.0.1:$SERVE_PORT" \
  --tls-ca "$WORK/ca1-ca.pem" --token p24-after-token-123456 2>&1 || true)"
printf '%s' "$OUT" | grep -qi "certificate\|verify\|tls" \
  || fail "a CA1 client was served after the rotation: $OUT"

# 2c. the OLD credential is refused by the new table
OUT="$("$EXE" produce --topic t --file "$WORK/in.txt" --remote "127.0.0.1:$SERVE_PORT" \
  --tls-ca "$WORK/ca2-ca.pem" --token p24-before-token-123456 2>&1 || true)"
printf '%s' "$OUT" | grep -q "code[[:space:]=]*9" \
  || fail "the removed credential still authenticates: $OUT"

# 2d. the reload is on the record, and the process never died
kill -0 "$SERVE_PID" 2>/dev/null || fail "the serve process died during rotation"
grep -q "TLS context rotated" "$WORK/serve.log" \
  || { cat "$WORK/serve.log"; fail "the serve log has no rotation note"; }
grep -q "credentials reloaded" "$WORK/serve.log" \
  || fail "the serve log has no credential-reload note"
pass "rotation without restart: new CA served, old CA refused, old credential refused, process alive with reload notes"

# ---- 3. the control plane rotates the same way ---------------------------
gen_cert ca3 sc-v1
cp "$WORK/sc-v1.pem" "$WORK/sc/server.pem"
cp "$WORK/sc-v1.key" "$WORK/sc/server.key"
"$EXE" sc --listen "127.0.0.1:$SC_PORT" --data-dir "$WORK/sc" \
  --tls-cert "$WORK/sc/server.pem" --tls-key "$WORK/sc/server.key" \
  > "$WORK/sc.log" 2>&1 &
SC_PID=$!
PIDS+=("$SC_PID")
wait_listen "$SC_PORT" || { cat "$WORK/sc.log"; fail "sc did not start"; }
mkdir -p "$WORK/spu-a"
"$EXE" spu --id spu-a --listen "127.0.0.1:19718" --data-dir "$WORK/spu-a" \
  --sc "127.0.0.1:$SC_PORT" --tls-ca "$WORK/ca3-ca.pem" \
  --tls-cert "$WORK/sc-v1.pem" --tls-key "$WORK/sc-v1.key" \
  > "$WORK/spu-a.log" 2>&1 &
SPU_PID=$!
PIDS+=("$SPU_PID")
REGISTERED=""
for _ in $(seq 1 40); do
  OUT="$("$EXE" cluster nodes --remote "127.0.0.1:$SC_PORT" --tls-ca "$WORK/ca3-ca.pem" 2>&1 || true)"
  printf '%s' "$OUT" | grep -q "spu-a" && { REGISTERED=yes; break; }
  sleep 0.25
done
[ -n "$REGISTERED" ] \
  || { echo "$OUT" | head -2; fail "the control plane did not answer under its own CA: $OUT"; }
gen_cert ca4 sc-v2
cp "$WORK/sc-v2.pem" "$WORK/sc/server.pem"
cp "$WORK/sc-v2.key" "$WORK/sc/server.key"
sleep 2.5
OUT="$("$EXE" cluster nodes --remote "127.0.0.1:$SC_PORT" --tls-ca "$WORK/ca4-ca.pem" 2>&1 || true)"
printf '%s' "$OUT" | grep -q "spu-a" \
  || { echo "$OUT" | head -2; fail "the control plane did not serve under the rotated CA: $OUT"; }
OUT="$("$EXE" cluster nodes --remote "127.0.0.1:$SC_PORT" --tls-ca "$WORK/ca3-ca.pem" 2>&1 || true)"
printf '%s' "$OUT" | grep -qi "certificate\|verify\|tls" \
  || fail "a client trusting the old CA was still served after rotation: $OUT"
kill -0 "$SC_PID" 2>/dev/null || fail "the sc process died during rotation"
grep -q "TLS context rotated" "$WORK/sc.log" \
  || fail "the sc log has no rotation note"
pass "the control plane serves under the rotated CA without a restart"

# ---- 4. auth without TLS is announced as cleartext -----------------------
mkdir -p "$WORK/plain"
printf '{"credentials":[{"name":"plain","token":"p24-plain-token-1234","role":"read-write"}]}' \
  > "$WORK/plain/auth.json"
"$EXE" serve --data-dir "$WORK/plain" --listen "127.0.0.1:19719" \
  > "$WORK/plain.log" 2>&1 &
PLAIN_PID=$!
PIDS+=("$PLAIN_PID")
wait_listen 19719 || { cat "$WORK/plain.log"; fail "the plain serve did not start"; }
wait_log "$WORK/plain.log" "credentials travel in cleartext" \
  || { cat "$WORK/plain.log"; fail "an auth-enabled plaintext listener did not announce the cleartext risk"; }
pass "auth enabled without TLS announces the cleartext risk at startup"

echo "E2E-P24-ROTATION PASS: 4 legs green"
