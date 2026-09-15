#!/bin/bash
# P1 gate: >=3 real data sources run end to end.
#   sources: file, stdin, HTTP GET (against a real python fixture server)
#   sinks:   stdout, HTTP POST (collected by the same fixture)
# All three chains run through `pipeline run --spec`.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXE="${MOONFLUX_EXE:-$ROOT/_build/native/release/build/apps/cli/cli.exe}"
[ -x "$EXE" ] || EXE="$ROOT/_build/native/debug/build/apps/cli/cli.exe"
[ -x "$EXE" ] || { echo "cli executable not found; run: moon build --target native" >&2; exit 1; }

WORK="$(mktemp -d /tmp/moonflux-e2e-conn.XXXXXX)"
PORT="${MOONFLUX_CONN_PORT:-19431}"
FIXTURE_PID=""
trap 'kill "$FIXTURE_PID" 2>/dev/null || true; rm -rf "$WORK"' EXIT

fail() { echo "E2E-CONNECTORS FAIL: $*" >&2; exit 1; }
pass() { echo "E2E-CONNECTORS PASS: $*"; }

# ---------- real HTTP fixture: GET /data, POST /sink -> collected file ----------
cat > "$WORK/fixture.py" <<'PY'
import http.server, socketserver, sys
port = int(sys.argv[1]); collector = sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/data":
            body = b"alpha\nbravo\ncharlie\n"
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404); self.end_headers()
    def do_POST(self):
        n = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(n)
        if self.path == "/sink":
            with open(collector, "ab") as f:
                f.write(body)
            self.send_response(200)
            self.send_header("Content-Length", "2")
            self.end_headers()
            self.wfile.write(b"ok")
        else:
            self.send_response(404); self.end_headers()
    def log_message(self, *a):
        pass
socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(("127.0.0.1", port), H) as srv:
    srv.serve_forever()
PY

python3 "$WORK/fixture.py" "$PORT" "$WORK/received.txt" > "$WORK/fixture.log" 2>&1 &
FIXTURE_PID=$!
for _ in $(seq 1 50); do
  lsof -i ":$PORT" -sTCP:LISTEN >/dev/null 2>&1 && break
  sleep 0.1
done
lsof -i ":$PORT" -sTCP:LISTEN >/dev/null 2>&1 || fail "fixture server did not start"
pass "HTTP fixture listening on 127.0.0.1:$PORT"

make_spec() { # $1 = source json, $2 = sink json, $3 = out
  cat > "$3" <<EOF
{
  "apiVersion": "moonflux.io/v1alpha1",
  "kind": "Pipeline",
  "metadata": { "name": "connector-demo" },
  "spec": {
    "source": $1,
    "transforms": [],
    "topic": { "name": "events" },
    "sink": $2
  }
}
EOF
}

# ---------- chain 1: file source -> stdout sink ----------
printf 'one\ntwo\n' > "$WORK/in.txt"
make_spec "{ \"type\": \"file\", \"path\": \"$WORK/in.txt\" }" '{ "type": "stdout" }' "$WORK/spec-file.json"
"$EXE" pipeline run --spec "$WORK/spec-file.json" --data-dir "$WORK/data-file" > "$WORK/out-file.txt" \
  || fail "file -> stdout run failed"
printf 'one\ntwo\n' > "$WORK/expect-file.txt"
diff -u "$WORK/expect-file.txt" "$WORK/out-file.txt" || fail "file -> stdout output"
pass "source 1/3 file -> stdout sink"

# ---------- chain 2: HTTP GET source -> stdout sink ----------
make_spec "{ \"type\": \"http\", \"url\": \"http://127.0.0.1:$PORT/data\" }" '{ "type": "stdout" }' "$WORK/spec-http.json"
"$EXE" pipeline run --spec "$WORK/spec-http.json" --data-dir "$WORK/data-http" > "$WORK/out-http.txt" \
  || fail "http -> stdout run failed"
printf 'alpha\nbravo\ncharlie\n' > "$WORK/expect-http.txt"
diff -u "$WORK/expect-http.txt" "$WORK/out-http.txt" || fail "http -> stdout output"
pass "source 2/3 http-get -> stdout sink"

# ---------- chain 3: stdin source -> HTTP POST sink ----------
make_spec '{ "type": "stdin" }' "{ \"type\": \"http\", \"url\": \"http://127.0.0.1:$PORT/sink\" }" "$WORK/spec-stdin.json"
printf 'delta\necho\nfoxtrot\n' | "$EXE" pipeline run --spec "$WORK/spec-stdin.json" --data-dir "$WORK/data-stdin" \
  > "$WORK/out-stdin.txt" || fail "stdin -> http run failed"
[ ! -s "$WORK/out-stdin.txt" ] || fail "stdin -> http must not write to stdout"
printf 'delta\necho\nfoxtrot\n' > "$WORK/expect-received.txt"
diff -u "$WORK/expect-received.txt" "$WORK/received.txt" || fail "http sink collector content"
pass "source 3/3 stdin -> http-post sink (fixture collected the batch)"

# ---------- a bad source URL fails loudly (no silent empty run) ----------
make_spec '{ "type": "http", "url": "http://127.0.0.1:9/nope" }' '{ "type": "stdout" }' "$WORK/spec-bad.json"
if "$EXE" pipeline run --spec "$WORK/spec-bad.json" --data-dir "$WORK/data-bad" > "$WORK/out-bad.txt" 2>&1; then
  fail "unreachable source must fail the run"
fi
grep -q "source" "$WORK/out-bad.txt" || fail "failure output lacks source context"
pass "unreachable source fails loudly with context"

kill "$FIXTURE_PID" 2>/dev/null || true
wait "$FIXTURE_PID" 2>/dev/null || true
echo "E2E-CONNECTORS: all green"
