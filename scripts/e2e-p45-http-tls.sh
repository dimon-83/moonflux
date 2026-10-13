#!/bin/bash
# E2E-P45-HTTP-TLS: http 源的 https/TLS（决策 91）
#
# 真实需求：某厂 PostgREST 是 **https**，而连接器原来只认 http://（`parse_http_url`
# 直接拒绝，还有 wbtest 钉着 ✗）。这条门禁证明 https 通了，并且证明**拒绝路径**也对——
# 与 P12 同一条纪律：安全面的门禁必须断言"拒绝"，而不只是断言"连通"（连通很容易是
# SSL_VERIFY_NONE 的假成功 ✗）。
#
#   1  https 但 spec 没给 ca：**校验期**按名拒绝（不是等到握手抛一句 OpenSSL 出来）
#   2  https 给了**错**的 ca：握手失败、**零记录**（错信任锚不能拿到数据）
#   3  https 给了对的 ca：数据流进来，且**对端**日志里确实收到 `Accept-Profile`
#      （证明请求头穿过 TLS 没有被丢）
#   4  证书必须**匹配主机名**：给一个只签了别的名字的 CA，即使它是我们信任的也拒
#      （`set_host` 这条 P12 纪律在 http 源上也生效）
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

EXE="${MOONFLUX_EXE:-$ROOT/_build/native/debug/build/apps/cli/cli.exe}"
WORK="$(mktemp -d /tmp/moonflux-p45.XXXXXX)"
PORT="${MOONFLUX_P45_PORT:-18541}"
PASS=0
SERVER_PID=""

fail() {
  echo "E2E-P45-HTTP-TLS FAIL: $*" >&2
  [ -f "$WORK/server.log" ] && tail -3 "$WORK/server.log" >&2
  exit 1
}
pass() { echo "E2E-P45-HTTP-TLS PASS: $*"; PASS=$((PASS + 1)); }
cleanup() {
  [ -n "$SERVER_PID" ] && kill -9 "$SERVER_PID" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

[ -x "$EXE" ] || { echo "missing $EXE (build first)" >&2; exit 1; }
command -v openssl > /dev/null 2>&1 || fail "openssl is required to mint the test certificates"
command -v python3 > /dev/null 2>&1 || fail "python3 is required for the fixture server"

# ---- certificates: a good one for 127.0.0.1, and a wrong trust anchor ----
#
# Extensions go in CONFIG FILES, not `-addext`: macOS ships LibreSSL, whose
# `-addext` accepts the flag and applies only one of the extensions — the result
# was a certificate python's ssl refused outright on the macOS runner
# ("[X509V3: INVALID_CERTIFICATE] invalid certificate"), while Linux's OpenSSL 3
# accepted the same invocation. A config file is the form both implement.
cat > "$WORK/server.cnf" <<'CNF'
[req]
prompt = no
distinguished_name = dn
x509_extensions = v3
[dn]
CN = 127.0.0.1
[v3]
basicConstraints = critical,CA:TRUE
keyUsage = critical,digitalSignature,keyEncipherment,keyCertSign
extendedKeyUsage = serverAuth
subjectAltName = IP:127.0.0.1
CNF
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -config "$WORK/server.cnf" \
  -keyout "$WORK/server.key" -out "$WORK/server.crt" > /dev/null 2>&1 ||
  fail "could not mint the server certificate"

cat > "$WORK/other.cnf" <<'CNF'
[req]
prompt = no
distinguished_name = dn
x509_extensions = v3
[dn]
CN = not-our-server
[v3]
basicConstraints = critical,CA:TRUE
keyUsage = critical,digitalSignature,keyEncipherment,keyCertSign
extendedKeyUsage = serverAuth
subjectAltName = DNS:not-our-server
CNF
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -config "$WORK/other.cnf" \
  -keyout "$WORK/other.key" -out "$WORK/other.crt" > /dev/null 2>&1 ||
  fail "could not mint the wrong trust anchor"

cat > "$WORK/body.json" <<'JSON'
[{"node_name":"CN_进水COD","var_value":1121.238403,"ts":"2026-10-14T04:16:00.520788+08:00","var_quality":192,"data_status":"正常"}]
JSON
: > "$WORK/requests.jsonl"
python3 "$ROOT/scripts/http_fixture_server.py" --port "$PORT" --body "$WORK/body.json" \
  --log "$WORK/requests.jsonl" --require "Accept-Profile=ia_csc" \
  --tls-cert "$WORK/server.crt" --tls-key "$WORK/server.key" > "$WORK/server.log" 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 80); do
  grep -q "fixture server on" "$WORK/server.log" 2>/dev/null && break
  sleep 0.1
done
grep -q "fixture server on https://" "$WORK/server.log" ||
  { cat "$WORK/server.log"; fail "the https fixture server did not start"; }

spec_with() { # $1 = ca json fragment, $2 = spec path, $3 = suffix
  cat > "$2" <<JSON
{
  "apiVersion": "moonflux.io/v1alpha1",
  "kind": "Pipeline",
  "metadata": { "name": "p45-$3" },
  "spec": {
    "source": { "type": "http", "url": "https://127.0.0.1:$PORT/value",
                "interval_ms": 200, "headers": { "Accept-Profile": "ia_csc" }$1 },
    "topic": { "name": "p45-$3-polls" },
    "transforms": [
      { "type": "wasm",
        "module": "$ROOT/_build/wasm/debug/build/apps/operator-identity/operator-identity.wasm",
        "config": {} }
    ],
    "sink": { "type": "stdout" }
  }
}
JSON
}

# ---- 1. https without a CA is refused at validation --------------------
cat > "$WORK/spec-noca.json" <<JSON
{
  "apiVersion": "moonflux.io/v1alpha1",
  "kind": "Pipeline",
  "metadata": { "name": "p45-noca" },
  "spec": {
    "source": { "type": "http", "url": "https://127.0.0.1:$PORT/value" },
    "topic": { "name": "p45-noca-polls" },
    "transforms": [], "sink": { "type": "stdout" }
  }
}
JSON
"$EXE" pipeline plan -f "$WORK/spec-noca.json" > "$WORK/plan-noca.txt" 2>&1 &&
  fail "1: https without a ca was accepted"
grep -q "https sources need ca" "$WORK/plan-noca.txt" ||
  { cat "$WORK/plan-noca.txt"; fail "1: the refusal does not name the missing key"; }
pass "1. https 缺 ca：**校验期**按名拒绝（\$(grep -o 'https sources need ca' "$WORK/plan-noca.txt" | head -1)）"

# ---- 2. a WRONG trust anchor gets no data ------------------------------
spec_with ', "ca": "'"$WORK"'/other.crt"' "$WORK/spec-wrongca.json" wrongca
"$EXE" pipeline run --data-dir "$WORK/d-wrong" --spec "$WORK/spec-wrongca.json" \
  > "$WORK/out-wrong.txt" 2> "$WORK/err-wrong.txt" &
RUN=$!
sleep 4
kill -9 $RUN 2>/dev/null
[ -s "$WORK/out-wrong.txt" ] &&
  { head -2 "$WORK/out-wrong.txt"; fail "2: data came out over an unverified connection"; }
grep -qiE "tls|certificate|verify" "$WORK/err-wrong.txt" ||
  { tail -3 "$WORK/err-wrong.txt"; fail "2: the failure does not read as a TLS refusal"; }
pass "2. 错的信任锚：握手被拒、**零记录**（$(grep -oiE 'tls[^"]{0,40}|certificate[^"]{0,40}' "$WORK/err-wrong.txt" | head -1)…）"

# ---- 3. the right CA: data flows, and the PEER saw the header ----------
REQS_BEFORE=$(wc -l < "$WORK/requests.jsonl" | tr -d ' ')
spec_with ', "ca": "'"$WORK"'/server.crt"' "$WORK/spec-good.json" good
"$EXE" pipeline run --data-dir "$WORK/d-good" --spec "$WORK/spec-good.json" \
  > "$WORK/out-good.txt" 2> "$WORK/err-good.txt" &
RUN=$!
sleep 4
kill -9 $RUN 2>/dev/null
sleep 0.5
[ -s "$WORK/out-good.txt" ] || { tail -3 "$WORK/err-good.txt"; fail "3: no data over https with the right CA"; }
grep -q '"var_value":1121.238403\|1121.238403' "$WORK/out-good.txt" ||
  { head -2 "$WORK/out-good.txt"; fail "3: the record body is not the fixture's"; }
pass "3. 对的 CA：https 取到数据（$(head -1 "$WORK/out-good.txt" | cut -c1-50)…）"

python3 - "$WORK/requests.jsonl" "$REQS_BEFORE" <<'PY' || fail "3/4: the peer did not see the request as expected"
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8") if l.strip()]
assert rows, "the fixture server logged nothing: the https request never arrived"
first = int(sys.argv[2])
new = rows[first:]
assert new, f"no request arrived over TLS (total {len(rows)})"
assert all(r["headers"].get("Accept-Profile") == "ia_csc" for r in new), \
    [r["headers"].get("Accept-Profile") for r in new]
print(f"peer saw Accept-Profile=ia_csc over {len(new)} TLS request(s)", file=sys.stderr)
PY
pass "3b. **对端**在 TLS 上确实收到了 Accept-Profile（请求头没有被 TLS 路径丢掉）"

# ---- 4. the certificate must name the host -----------------------------
# our own CA, but a certificate for another name: refusing this is what
# `set_host` is for, and a client that only checks the CA would accept it
openssl req -newkey rsa:2048 -nodes -keyout "$WORK/mismatch.key" -out "$WORK/mismatch.csr" \
  -subj "/CN=not-127.0.0.1" > /dev/null 2>&1 || fail "4: could not build the mismatched CSR"
cat > "$WORK/mismatch.cnf" <<'CNF'
[v3]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = DNS:somewhere-else.example
CNF
openssl x509 -req -in "$WORK/mismatch.csr" -CA "$WORK/server.crt" -CAkey "$WORK/server.key" \
  -CAcreateserial -days 2 -out "$WORK/mismatch.crt" \
  -extfile "$WORK/mismatch.cnf" -extensions v3 > /dev/null 2>&1 ||
  fail "4: could not sign the mismatched certificate"
MISMATCH_PORT=$((PORT + 1))
: > "$WORK/requests-mismatch.jsonl"
python3 "$ROOT/scripts/http_fixture_server.py" --port "$MISMATCH_PORT" --body "$WORK/body.json" \
  --log "$WORK/requests-mismatch.jsonl" \
  --tls-cert "$WORK/mismatch.crt" --tls-key "$WORK/mismatch.key" > "$WORK/server-mismatch.log" 2>&1 &
MISMATCH_PID=$!
for _ in $(seq 1 80); do
  grep -q "fixture server on" "$WORK/server-mismatch.log" 2>/dev/null && break
  sleep 0.1
done
sed "s/:$PORT/:$MISMATCH_PORT/" "$WORK/spec-good.json" > "$WORK/spec-mismatch.json"
"$EXE" pipeline run --data-dir "$WORK/d-mismatch" --spec "$WORK/spec-mismatch.json" \
  > "$WORK/out-mismatch.txt" 2> "$WORK/err-mismatch.txt" &
RUN=$!
sleep 4
kill -9 $RUN 2>/dev/null
kill -9 $MISMATCH_PID 2>/dev/null
[ -s "$WORK/out-mismatch.txt" ] &&
  { head -2 "$WORK/out-mismatch.txt"; fail "4: a certificate for another host name was accepted"; }
pass "4. 名字不匹配的证书被拒（只校验 CA 的客户端会接受它——这条正是 set_host 的意义）"

# ---- 5. SNI decides which certificate the server hands over -----------
# The bug this leg exists for: the shim pinned the host for VERIFICATION but
# never sent SNI, so a multi-vhost server answered with its default certificate
# and every handshake failed with "unable to get local issuer certificate"
# (code 20) — while openssl s_client, which sends SNI, verified with the same
# bundle. No single-certificate fixture can see the difference, which is why the
# earlier legs passed while the real host failed.
#
# The default certificate here is deliberately the WRONG one for `localhost`;
# only a client that names it gets the certificate that can verify. The leg
# asserts BOTH that data arrived AND that the peer logged the name it was given —
# and the check below proves the default certificate could not have verified, so
# the leg has teeth.
# A proper localhost CHAIN (CA -> leaf), not a self-signed CA-as-server: the
# client trusts the CA and the leaf must carry the name it asked for.
cat > "$WORK/lhca.cnf" <<'CNF'
[req]
prompt = no
distinguished_name = dn
x509_extensions = v3
[dn]
CN = p45 localhost CA
[v3]
basicConstraints = critical,CA:TRUE
keyUsage = critical,keyCertSign,cRLSign
CNF
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -config "$WORK/lhca.cnf" \
  -keyout "$WORK/lhca.key" -out "$WORK/lhca.crt" > /dev/null 2>&1 ||
  fail "5: could not mint the localhost CA"
openssl req -new -newkey rsa:2048 -nodes -subj "/CN=localhost" \
  -keyout "$WORK/localhost.key" -out "$WORK/localhost.csr" > /dev/null 2>&1 ||
  fail "5: could not build the localhost CSR"
cat > "$WORK/localhost.ext" <<'EXT'
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = DNS:localhost
EXT
openssl x509 -req -in "$WORK/localhost.csr" -CA "$WORK/lhca.crt" -CAkey "$WORK/lhca.key" \
  -CAcreateserial -days 2 -extfile "$WORK/localhost.ext" -out "$WORK/localhost.crt" \
  > /dev/null 2>&1 || fail "5: could not sign the localhost certificate"
if openssl verify -CAfile "$WORK/lhca.crt" -verify_hostname localhost "$WORK/server.crt" \
  > /dev/null 2>&1; then
  fail "5: the default certificate verifies for localhost, so this leg proves nothing"
fi

# `openssl s_server` does SNI natively (-servername + -cert2/-key2) and prints
# the name it received to stderr — a peer view we can assert. python's
# sni_callback was tried first and swapped nothing: the client kept receiving the
# DEFAULT certificate (it failed with "self-signed certificate", code 18, which
# is what the default is here).
# A fixture that REFUSES the handshake unless SNI carries the expected name, so
# "data arrived" is itself the proof that the name went out. This is the shape
# `openssl s_server -servername` would give; LibreSSL's s_server does not support
# the -cert2/-key2 pair it needs (measured: it printed usage), and python's
# sni_callback cannot swap certificates usefully here (the client kept receiving
# the default certificate), so the refusal is the discriminator instead.
SNI_PORT=$((PORT + 2))
: > "$WORK/requests-sni.jsonl"
python3 "$ROOT/scripts/http_fixture_server.py" --port "$SNI_PORT" --body "$WORK/body.json" \
  --log "$WORK/requests-sni.jsonl" --tls-cert "$WORK/localhost.crt" \
  --tls-key "$WORK/localhost.key" --require-sni localhost > "$WORK/server-sni.log" 2>&1 &
SNI_PID=$!
for _ in $(seq 1 80); do
  grep -q "fixture server on" "$WORK/server-sni.log" 2>/dev/null && break
  sleep 0.1
done

# (a) the IP form sends SNI=127.0.0.1, which the fixture refuses: no data, and a
#     named TLS failure rather than a timeout
sed -e "s/127.0.0.1:$PORT/127.0.0.1:$SNI_PORT/" \
    -e "s#\"ca\": \"[^\"]*\"#\"ca\": \"$WORK/lhca.crt\"#" \
    "$WORK/spec-good.json" > "$WORK/spec-sni-ip.json"
"$EXE" pipeline run --data-dir "$WORK/d-sni-ip" --spec "$WORK/spec-sni-ip.json" \
  > "$WORK/out-sni-ip.txt" 2> "$WORK/err-sni-ip.txt" &
RUN=$!
sleep 4
kill -9 $RUN 2>/dev/null
[ -s "$WORK/out-sni-ip.txt" ] &&
  { head -2 "$WORK/out-sni-ip.txt"; fail "5: the fixture served a connection whose SNI it should have refused"; }

# (b) naming localhost satisfies it: data arrives
sed -e "s/127.0.0.1:$PORT/localhost:$SNI_PORT/" \
    -e "s#\"ca\": \"[^\"]*\"#\"ca\": \"$WORK/lhca.crt\"#" \
    "$WORK/spec-good.json" > "$WORK/spec-sni.json"
"$EXE" pipeline run --data-dir "$WORK/d-sni" --spec "$WORK/spec-sni.json" \
  > "$WORK/out-sni.txt" 2> "$WORK/err-sni.txt" &
RUN=$!
sleep 4
kill -9 $RUN 2>/dev/null
kill -9 "$SNI_PID" 2>/dev/null
[ -s "$WORK/out-sni.txt" ] ||
  { tail -3 "$WORK/err-sni.txt"; fail "5: no data when the handshake requires SNI"; }
grep -q '"sni": "localhost"' "$WORK/requests-sni.jsonl" ||
  { head -2 "$WORK/requests-sni.jsonl"; fail "5: the peer never saw the SNI name"; }
pass "5. 客户端真的发 SNI（对端 stderr/日志看到 localhost，且名字不对时它拒握手、零记录）"

echo "E2E-P45-HTTP-TLS: $PASS passed, 0 failed"
