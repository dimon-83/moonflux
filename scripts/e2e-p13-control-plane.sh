#!/bin/bash
# P13 gate: the control plane serves many connections from one loop.
#
# The milestone exists because of a measured failure (P12/T59): with a
# one-connection-at-a-time control plane, a peer that connected and said
# nothing held the loop for a handshake deadline, and enough of them cost
# a healthy node its liveness window — the control plane then declared a
# live node dead and ran an election nobody needed.
#
#   1. silent peers (TLS handshake stalls + half-sent frames) do not cost
#      a healthy node its liveness, and trigger no election
#   2. a client stuck mid-frame does not delay another client's command
#   3. the security face is unchanged by the new scheduling: no
#      credential refused, a client credential still cannot REGISTER,
#      TLS is still required
#   4. a node that really dies *is* still declared offline (the
#      counter-leg: "no longer wrong" must not mean "no longer checking")
#   5. concurrent clients each get their own correct answer
#
# The port speaks TLS on purpose: a "silent peer" is only expensive when
# there is a handshake to stall, so a plaintext control plane would make
# leg 1 pass for the wrong reason.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXE="${MOONFLUX_EXE:-$ROOT/_build/native/debug/build/apps/cli/cli.exe}"
[ -x "$EXE" ] || EXE="$ROOT/_build/native/release/build/apps/cli/cli.exe"
[ -x "$EXE" ] || { echo "cli executable not found; run: moon build --target native" >&2; exit 1; }
PROBE="$ROOT/scripts/mfs_probe.py"

WORK="$(mktemp -d /tmp/moonflux-p13-control.XXXXXX)"
SC_PORT="${MOONFLUX_P13_SC_PORT:-19851}"
A_PORT="${MOONFLUX_P13_SPU_A_PORT:-19852}"
B_PORT="${MOONFLUX_P13_SPU_B_PORT:-19853}"
C_PORT="${MOONFLUX_P13_SPU_C_PORT:-19854}"
TOPIC="${MOONFLUX_P13_TOPIC:-events}"
SC="127.0.0.1:$SC_PORT"
PIDS=()
cleanup() {
  for pid in "${PIDS[@]}"; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
    [ -n "$pid" ] && wait "$pid" 2>/dev/null || true
  done
}
trap 'cleanup; rm -rf "$WORK"' EXIT

fail() { echo "E2E-P13-CONTROL FAIL: $*" >&2; exit 1; }
pass() { echo "E2E-P13-CONTROL PASS: $*"; }

wait_listen() { # $1 = port
  for _ in $(seq 1 60); do
    lsof -i ":$1" -sTCP:LISTEN > /dev/null 2>&1 && return 0
    sleep 0.1
  done
  return 1
}

wait_log() { # $1 = file, $2 = extended regex, $3 = seconds (default 10)
  # The port opens before the server has announced its modes (auth table,
  # TLS context). Checking once, immediately, is a race the dev machine
  # wins and CI's cold runner loses — it failed here with a log holding
  # only the "listening" line. Poll the announcement instead.
  local file=$1 pattern=$2 tries=$(( ${3:-10} * 20 ))
  while [ "$tries" -gt 0 ]; do
    grep -qE "$pattern" "$file" 2>/dev/null && return 0
    sleep 0.05
    tries=$((tries - 1))
  done
  return 1
}

# Two kinds of silent peer, both over TLS (the port requires it):
#
#   stall-handshake: connects and never speaks TLS. The server's handshake
#     runs into its deadline — the expensive one, and the reason the hub
#     runs at most one per round.
#   half-frame: completes the handshake, then sends a frame header that
#     promises 8 KiB and delivers 4 bytes. A blocking reader sits on it;
#     the poll-driven loop keeps serving everyone else.
prober() { # $1 = mode, $2 = seconds
  python3 - "$1" "$2" "$WORK/certs/ca.pem" "$WORK/certs/client.pem" \
    "$WORK/certs/client.key" "$SC_PORT" <<'PY' &
import socket, ssl, sys, time
mode, hold = sys.argv[1], float(sys.argv[2])
ca, cert, key, port = sys.argv[3], sys.argv[4], sys.argv[5], int(sys.argv[6])
socks = []
for _ in range(2):
    try:
        raw = socket.create_connection(("127.0.0.1", port), timeout=3)
        if mode == "half-frame":
            ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
            ctx.load_verify_locations(ca)
            ctx.load_cert_chain(cert, key)
            s = ctx.wrap_socket(raw, server_hostname="localhost")
            s.sendall(b"MFS" + bytes([2, 9]) + (0).to_bytes(4, "big") + (8192).to_bytes(4, "big"))
            s.sendall(b"\x00" * 4)
        else:
            s = raw          # connected, and that is all: no ClientHello
        socks.append(s)
    except (OSError, ssl.SSLError):
        pass
time.sleep(hold)
for s in socks:
    try:
        s.close()
    except OSError:
        pass
PY
  PIDS+=("$!")
}

command -v openssl > /dev/null 2>&1 || {
  echo "E2E-P13-CONTROL SKIP: openssl not found (the handshake-budget legs need TLS)" >&2
  exit 0
}

# ---- certificates -------------------------------------------------------
mkdir -p "$WORK/certs"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$WORK/certs/ca.key" \
  -out "$WORK/certs/ca.pem" -days 2 -subj "/CN=moonflux-p13-ca" 2>/dev/null
gen_cert() { # $1 = name
  openssl req -newkey rsa:2048 -nodes -keyout "$WORK/certs/$1.key" \
    -out "$WORK/certs/$1.csr" -subj "/CN=$1" 2>/dev/null
  printf 'subjectAltName=DNS:%s,DNS:localhost,IP:127.0.0.1\n' "$1" > "$WORK/certs/$1.ext"
  openssl x509 -req -in "$WORK/certs/$1.csr" -CA "$WORK/certs/ca.pem" \
    -CAkey "$WORK/certs/ca.key" -CAcreateserial -out "$WORK/certs/$1.pem" \
    -days 2 -extfile "$WORK/certs/$1.ext" 2>/dev/null
}
for name in sc client spu-a spu-b spu-c; do gen_cert "$name"; done
CA="$WORK/certs/ca.pem"
CLIENT_TLS=(--tls-ca "$CA" --tls-cert "$WORK/certs/client.pem" --tls-key "$WORK/certs/client.key")
ROOT_FLAGS=(--token root-token-123456 "${CLIENT_TLS[@]}")

# ---- cluster up ---------------------------------------------------------
mkdir -p "$WORK/sc" "$WORK/spu-a" "$WORK/spu-b" "$WORK/spu-c"
cat > "$WORK/auth.json" <<'JSON'
{"credentials":[
  {"name":"root","token":"root-token-123456","role":"root"},
  {"name":"spu-a","token":"spu-a-node-token","role":"node"},
  {"name":"spu-b","token":"spu-b-node-token","role":"node"},
  {"name":"spu-c","token":"spu-c-node-token","role":"node"},
  {"name":"alice","token":"alice-secret-1234","role":"read-write"}
]}
JSON
for d in sc spu-a spu-b spu-c; do cp "$WORK/auth.json" "$WORK/$d/auth.json"; done

"$EXE" sc --listen "$SC" --data-dir "$WORK/sc" \
  --tls-cert "$WORK/certs/sc.pem" --tls-key "$WORK/certs/sc.key" \
  --tls-ca "$CA" --tls-require-client > "$WORK/sc.log" 2>&1 &
PIDS+=("$!")
wait_listen "$SC_PORT" || { cat "$WORK/sc.log"; fail "sc did not start"; }
wait_log "$WORK/sc.log" "serving connections concurrently" 15 \
  || { cat "$WORK/sc.log"; fail "the control plane is not serving concurrently"; }
wait_log "$WORK/sc.log" "authentication ENABLED" || { cat "$WORK/sc.log"; fail "auth was not announced"; }
wait_log "$WORK/sc.log" "TLS ENABLED" || { cat "$WORK/sc.log"; fail "TLS was not announced"; }

start_spu() { # $1 = id, $2 = port, $3 = token
  "$EXE" spu --id "$1" --listen "127.0.0.1:$2" --data-dir "$WORK/$1" \
    --sc "$SC" --token "$3" \
    --tls-cert "$WORK/certs/$1.pem" --tls-key "$WORK/certs/$1.key" \
    --tls-ca "$CA" --tls-require-client > "$WORK/$1.log" 2>&1 &
  PIDS+=("$!")
}
start_spu spu-a "$A_PORT" spu-a-node-token
start_spu spu-b "$B_PORT" spu-b-node-token
start_spu spu-c "$C_PORT" spu-c-node-token
for p in "$A_PORT" "$B_PORT" "$C_PORT"; do
  wait_listen "$p" || fail "a node did not start"
done

nodes_text() { "$EXE" cluster nodes --remote "$SC" "${ROOT_FLAGS[@]}" 2>/dev/null || true; }

for _ in $(seq 1 80); do
  REGISTERED="$(nodes_text)"
  if printf '%s\n' "$REGISTERED" | grep -q spu-a &&
    printf '%s\n' "$REGISTERED" | grep -q spu-b &&
    printf '%s\n' "$REGISTERED" | grep -q spu-c; then
    break
  fi
  sleep 0.25
done
printf '%s\n' "$REGISTERED" | grep -q spu-c || { cat "$WORK/sc.log"; fail "not all three nodes registered"; }
pass "cluster up: TLS + authentication + three registered nodes, control plane poll-driven"

# a real pipeline and topic: with data placed, "no node was declared
# offline" also means "no election was held" — and an election nobody
# needed is the actual cost this milestone removes
cat > "$WORK/spec.json" <<JSON
{
  "apiVersion": "moonflux.io/v1alpha1",
  "kind": "Pipeline",
  "metadata": { "name": "control-plane" },
  "spec": {
    "source": { "type": "file", "path": "$WORK/in.txt" },
    "transforms": [],
    "topic": { "name": "$TOPIC" },
    "sink": { "type": "stdout" }
  }
}
JSON
printf 'seed\n' > "$WORK/in.txt"
"$EXE" pipeline apply -f "$WORK/spec.json" --remote "$SC" "${ROOT_FLAGS[@]}" > /dev/null \
  || { cat "$WORK/sc.log"; fail "root could not apply the pipeline"; }
"$EXE" topic create --name "$TOPIC" --partitions 3 --replication-factor 2 \
  --remote "$SC" "${ROOT_FLAGS[@]}" > /dev/null || fail "root could not create the topic"
HOSTED=0
for _ in $(seq 1 80); do
  HOSTED=0
  for node in spu-a spu-b spu-c; do
    [ "$(grep -c "hosting $TOPIC\[" "$WORK/$node.log" || true)" -ge 1 ] && HOSTED=$((HOSTED + 1))
  done
  [ "$HOSTED" -eq 3 ] && break
  sleep 0.25
done
[ "$HOSTED" -eq 3 ] || { cat "$WORK/sc.log"; fail "not every node adopted a partition of $TOPIC"; }
pass "a 3-partition topic is placed across the three nodes"

# ---- 1. silent peers must not cost a healthy node its liveness ---------
# Three counters that must stay put: a node declared offline, a partition
# re-elected, a nomination offered. Each is the *symptom* of a control
# plane that was too busy to hear a heartbeat.
symptom_count() { grep -chE "is offline|leader of|offering" "$WORK/sc.log" || true; }

BEFORE_SYMPTOMS="$(symptom_count)"
# 4 handshake stalls + 2 half-frames, held for 8s inside a 3s liveness
# window. Without the one-handshake-per-round bound this is 4 x 500ms of
# loop stall inside that window — enough to sweep a healthy node out.
prober stall-handshake 8
prober stall-handshake 8
prober stall-handshake 8
prober stall-handshake 8
prober half-frame 8
prober half-frame 8
sleep 9
AFTER_SYMPTOMS="$(symptom_count)"
[ "$BEFORE_SYMPTOMS" = "$AFTER_SYMPTOMS" ] || {
  grep -E "is offline|leader of|offering" "$WORK/sc.log"
  for node in spu-a spu-b spu-c; do
    echo "--- $node ---"
    tail -6 "$WORK/$node.log"
  done
  fail "silent peers cost a live node its liveness: offline/election lines went $BEFORE_SYMPTOMS → $AFTER_SYMPTOMS"
}
LIVE="$("$EXE" cluster nodes --remote "$SC" "${ROOT_FLAGS[@]}" 2>&1 || true)"
printf '%s\n' "$LIVE" | grep -q spu-a || {
  printf '%s\n' "$LIVE"
  echo "sc pid \${PIDS[0]} alive: $(kill -0 "\${PIDS[0]}" 2>/dev/null && echo yes || echo no)"
  echo "--- sc.log ---"
  tail -25 "$WORK/sc.log"
  fail "spu-a vanished from the table"
}
printf '%s\n' "$LIVE" | grep -q spu-c || { cat "$WORK/sc.log"; fail "spu-c vanished from the table"; }
pass "1. six silent peers (4 handshake stalls + 2 half-frames) cost no node its liveness and triggered no election"
pass "1b. the node table still answers with all three nodes after the probe window"

# ---- 2. a slow client does not block another client's command ----------
prober half-frame 4
sleep 0.5
START_MS="$(python3 -c 'import time; print(int(time.time()*1000))')"
DURING="$(nodes_text)"
END_MS="$(python3 -c 'import time; print(int(time.time()*1000))')"
ELAPSED=$((END_MS - START_MS))
printf '%s\n' "$DURING" | grep -q spu-b \
  || { cat "$WORK/sc.log"; fail "a command failed while a slow client was mid-frame"; }
[ "$ELAPSED" -lt 1000 ] || fail "a command took ${ELAPSED}ms while a slow client was mid-frame"
pass "2. a client stuck mid-frame did not delay another client's command (${ELAPSED}ms)"

# ---- 3. the security face is unchanged by the new scheduling -----------
OUT="$("$EXE" topic list --remote "$SC" "${CLIENT_TLS[@]}" 2>&1 || true)"
printf '%s' "$OUT" | grep -qE "code[ =]9" \
  || fail "an unauthenticated client was served after the refactor: $OUT"
pass "3a. no credential is still refused: $(printf '%s' "$OUT" | sed 's/^error: //')"

OUT="$(python3 "$PROBE" "$SC" --cmd 7 --payload "node:fake:spu:0:127.0.0.1:19999" \
  --token alice-secret-1234 --tls-ca "$CA" \
  --tls-cert "$WORK/certs/client.pem" --tls-key "$WORK/certs/client.key" 2>&1 || true)"
printf '%s' "$OUT" | grep -q "REFUSED 10" \
  || fail "a client credential could REGISTER a node after the refactor: $OUT"
pass "3b. a client credential still cannot REGISTER: $(printf '%s' "$OUT" | sed 's/^REFUSED /code /')"

OUT="$("$EXE" topic list --remote "$SC" --token root-token-123456 2>&1 || true)"
printf '%s' "$OUT" | grep -q "error" \
  || fail "a plaintext client was served by the TLS control plane: $OUT"
pass "3c. TLS is still required on the control port (a plaintext client is refused)"

# ---- 4. a node that really dies is still declared offline --------------
kill "${PIDS[2]}" 2>/dev/null || true   # spu-b
wait "${PIDS[2]}" 2>/dev/null || true
DEADLINE=$(( $(python3 -c 'import time; print(int(time.time()))') + 12 ))
while [ "$(python3 -c 'import time; print(int(time.time()))')" -lt "$DEADLINE" ]; do
  if grep -q "spu-b is offline" "$WORK/sc.log"; then break; fi
  sleep 0.25
done
grep -q "spu-b is offline" "$WORK/sc.log" \
  || { cat "$WORK/sc.log"; fail "a node that died was never declared offline (liveness detection was lost)"; }
pass "4. a node that really dies is still declared offline ($(grep -o 'spu-b is offline.*' "$WORK/sc.log" | head -1))"

# ---- 5. concurrent clients each get their own answer -------------------
python3 - "$SC_PORT" "$WORK/certs/ca.pem" "$WORK/certs/client.pem" "$WORK/certs/client.key" <<'PY' \
  || fail "concurrent clients did not each get their own correct answer"
import ssl, socket, sys, threading
port, ca, cert, key = int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
results = {}

def call(name, cmd, expect):
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.load_verify_locations(ca)
    ctx.load_cert_chain(cert, key)
    raw = socket.create_connection(("127.0.0.1", port), timeout=5)
    s = ctx.wrap_socket(raw, server_hostname="localhost")

    def send(c, payload=b""):
        s.sendall(b"MFS" + bytes([2, c]) + (1).to_bytes(4, "big") + len(payload).to_bytes(4, "big") + payload)

    def recv():
        head = b""
        while len(head) < 13:
            chunk = s.recv(13 - len(head))
            if not chunk:
                raise EOFError("closed")
            head += chunk
        length = int.from_bytes(head[9:13], "big")
        body = b""
        while len(body) < length:
            body += s.recv(length - len(body))
        return head[4], body

    try:
        send(1, (1).to_bytes(4, "big") + (0).to_bytes(4, "big"))   # HELLO
        recv()
        send(35, b"root-token-123456")                              # AUTH
        cmd_reply, _ = recv()
        if cmd_reply == 6:
            results[name] = "auth refused"
            return
        send(cmd, b"")
        _, payload = recv()
        body = payload.decode(errors="replace")
        results[name] = "ok" if expect in body else f"wrong payload: {body[:60]}"
    except Exception as error:                                      # noqa: BLE001
        results[name] = f"{type(error).__name__}: {error}"
    finally:
        s.close()

threads = [threading.Thread(target=call, args=(f"nodes-{i}", 9, "spu-a")) for i in range(2)] + \
          [threading.Thread(target=call, args=(f"topics-{i}", 16, "")) for i in range(2)]
for t in threads:
    t.start()
for t in threads:
    t.join()
bad = {k: v for k, v in results.items() if v != "ok"}
if bad:
    print("FAIL", bad)
    sys.exit(1)
print(f"ok: {len(results)} concurrent replies, each matching its own request")
PY
pass "5. four concurrent clients each got their own correct answer"

pass "P13 control-plane gate: 5 legs green"
