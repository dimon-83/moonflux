#!/bin/bash
# P4 (T29) gate: WebSocket transport — a browser-shaped client speaks
# the *same* protocol as the CLI, over the same port.
#
#   1. one port serves both: an MFS-speaking CLI and an HTTP-upgrading
#      WebSocket client both reach the broker, with no second listener
#   2. the handshake is RFC 6455 (the accept key is checked against the
#      RFC's worked example by the unit tests; here it has to work with
#      a real client)
#   3. HELLO/PRODUCE/FETCH over WebSocket produce the same records as
#      the TCP path — the protocol did not fork
#   4. a non-upgrade HTTP request is answered, not left hanging
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXE="${MOONFLUX_EXE:-$ROOT/_build/native/release/build/apps/cli/cli.exe}"
[ -x "$EXE" ] || EXE="$ROOT/_build/native/debug/build/apps/cli/cli.exe"
[ -x "$EXE" ] || { echo "cli executable not found; run: moon build --target native" >&2; exit 1; }

WORK="$(mktemp -d /tmp/moonflux-p4-ws.XXXXXX)"
PORT="${MOONFLUX_WS_PORT:-19401}"
SERVER_PID=""
trap 'kill "$SERVER_PID" 2>/dev/null || true; rm -rf "$WORK"' EXIT

fail() { echo "E2E-P4-WS FAIL: $*" >&2; exit 1; }
pass() { echo "E2E-P4-WS PASS: $*"; }

wait_listen() {
  for _ in $(seq 1 60); do
    lsof -i ":$1" -sTCP:LISTEN > /dev/null 2>&1 && return 0
    sleep 0.1
  done
  return 1
}

printf 'ws1\nws2\n' > "$WORK/in.txt"
# the batch frame the WebSocket client will hand to the broker: built by
# the project's own generator so the bytes follow the protocol's rules
python3 "$ROOT/tools/gen_ws_batch.py" "$WORK/batch.bin" > /dev/null \
  || { echo "generator failed" >&2; exit 1; }
"$EXE" pipeline apply -f /dev/stdin --data-dir "$WORK/data" <<EOF > /dev/null
{
  "apiVersion": "moonflux.io/v1alpha1",
  "kind": "Pipeline",
  "metadata": { "name": "ws-demo" },
  "spec": {
    "source": { "type": "file", "path": "$WORK/in.txt" },
    "transforms": [],
    "topic": { "name": "wsdemo" },
    "sink": { "type": "stdout" }
  }
}
EOF

"$EXE" serve --data-dir "$WORK/data" --listen "127.0.0.1:$PORT" --ws > "$WORK/serve.log" 2>&1 &
SERVER_PID=$!
wait_listen "$PORT" || { cat "$WORK/serve.log"; fail "serve did not start"; }

# ---- 1+2+3: a WebSocket client speaks the frame protocol ---------------
python3 - "$PORT" "$WORK" <<'PY' || fail "websocket client failed"
import base64, hashlib, os, socket, struct, sys

port, work = int(sys.argv[1]), sys.argv[2]

def ws_connect(port):
    s = socket.create_connection(("127.0.0.1", port), timeout=5)
    key = base64.b64encode(os.urandom(16)).decode()
    req = (
        "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\n"
        "Connection: Upgrade\r\nSec-WebSocket-Key: %s\r\n"
        "Sec-WebSocket-Version: 13\r\n\r\n" % key
    )
    s.sendall(req.encode())
    head = b""
    while b"\r\n\r\n" not in head:
        chunk = s.recv(1)
        if not chunk:
            raise SystemExit("handshake closed early")
        head += chunk
    text = head.decode()
    if "101" not in text.split("\r\n")[0]:
        raise SystemExit("no 101: %r" % text[:80])
    expected = base64.b64encode(
        hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()
    ).decode()
    if ("Sec-WebSocket-Accept: %s" % expected) not in text:
        raise SystemExit("accept key mismatch:\n%s" % text)
    return s

def send_frame(s, opcode, payload):
    mask = os.urandom(4)
    header = bytes([0x80 | opcode])
    n = len(payload)
    if n < 126:
        header += bytes([0x80 | n])
    elif n <= 65535:
        header += bytes([0x80 | 126]) + struct.pack(">H", n)
    else:
        header += bytes([0x80 | 127]) + struct.pack(">Q", n)
    masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
    s.sendall(header + mask + masked)

def recv_exact(s, n):
    out = b""
    while len(out) < n:
        chunk = s.recv(n - len(out))
        if not chunk:
            raise SystemExit("closed mid-frame")
        out += chunk
    return out

def recv_frame(s):
    h = recv_exact(s, 2)
    opcode = h[0] & 0x0F
    length = h[1] & 0x7F
    if length == 126:
        length = struct.unpack(">H", recv_exact(s, 2))[0]
    elif length == 127:
        length = struct.unpack(">Q", recv_exact(s, 8))[0]
    return opcode, recv_exact(s, length)

def mfs(cmd, rid, payload=b""):
    return b"MFS" + bytes([2, cmd]) + struct.pack(">II", rid, len(payload)) + payload

s = ws_connect(port)

# HELLO (cmd 1): major 1, minor 0
send_frame(s, 2, mfs(1, 0, struct.pack(">II", 1, 0)))
opcode, payload = recv_frame(s)
assert opcode == 2, opcode
assert payload[:3] == b"MFS", payload[:3]
assert payload[4] == 2, "expected WELCOME (2), got %d" % payload[4]

# PRODUCE (cmd 3): leb128 topic length + topic + one batch frame
# (the frame is the rest of the payload; there is no length prefix in
# the request — the reply carries the assigned offset instead)
topic = b"wsdemo"
batch = open(os.path.join(work, "batch.bin"), "rb").read()
produce = bytes([len(topic)]) + topic + batch
send_frame(s, 2, mfs(3, 1, produce))
opcode, payload = recv_frame(s)
assert payload[4] == 5, "expected OK (5), got %d" % payload[4]
base, count = struct.unpack(">qI", payload[13:25])
print("produced at base %d, count %d" % (base, count))
assert count == 3, count

# FETCH (cmd 4): read them back over the same socket
fetch = bytes([len(topic)]) + topic + struct.pack(">qI", 0, 100)  # uleb128 len + topic + from + max
send_frame(s, 2, mfs(4, 2, fetch))
opcode, payload = recv_frame(s)
assert payload[4] == 5, "expected OK (5), got %d" % payload[4]
body = payload[13:]
batch_count, frame_len = struct.unpack(">II", body[:8])
assert batch_count == 1, batch_count
frame = body[8:8 + frame_len]
assert frame[:3] == b"MFB", frame[:3]
# the stored frame is the sent frame with the broker's base offset in
# place — every other byte identical. That is the whole point of the
# protocol's offset handling, asserted across the browser transport.
sent = bytearray(batch)
got = bytearray(frame)
assert got[8:16] == struct.pack(">q", base), (got[8:16], base)
got[8:16] = sent[8:16]
assert bytes(got) == bytes(sent), "the fetched frame is not the produced frame"
print("fetched %d bytes: byte-identical to what was sent (modulo the assigned base)" % frame_len)

# close politely
send_frame(s, 8, b"")
s.close()
PY
pass "a WebSocket client completed HELLO → PRODUCE → FETCH (same frames as TCP)"

# ---- 1b: the CLI path still works on the same port ---------------------
"$EXE" produce --topic wsdemo --file "$WORK/in.txt" --remote "127.0.0.1:$PORT" > /dev/null \
  || fail "the native CLI path broke on the websocket port"
"$EXE" consume --topic wsdemo --remote "127.0.0.1:$PORT" | cut -f4- > "$WORK/out.txt"
# first the three records the WebSocket client produced (the vector's
# bytes decoded: value "61" -> a, value "6262" -> bb, then an empty
# value), then the two from the file source
printf 'a\nbb\n\nws1\nws2\n' > "$WORK/want.txt"
diff -u "$WORK/want.txt" "$WORK/out.txt" \
  || { cat "$WORK/out.txt"; fail "the TCP path and the WS path disagree about the topic"; }
pass "the same port still serves an MFS-speaking CLI (both write and read)"

# ---- 4: an HTTP request that is not an upgrade is answered -------------
python3 - "$PORT" <<'PY' || fail "a plain HTTP request was not answered"
import socket, sys
port = int(sys.argv[1])
s = socket.create_connection(("127.0.0.1", port), timeout=5)
s.sendall(b"GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
try:
    data = s.recv(256)
except socket.timeout:
    raise SystemExit("no answer to a plain HTTP request (it hung)")
if not data:
    raise SystemExit("connection closed with no answer at all")
text = data.decode(errors="replace")
if "400" not in text.split("\r\n")[0]:
    raise SystemExit("expected a 400, got: %r" % text[:60])
if "not a websocket" not in text:
    raise SystemExit("the refusal does not say why: %r" % text[:160])
print("answered: %s" % text.split("\r\n")[0])
s.close()
PY
pass "a non-upgrade HTTP request is answered with a 400 that says why"

echo "E2E-P4-WS: all green"
