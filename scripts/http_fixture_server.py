#!/usr/bin/env python3
"""A tiny HTTP fixture server for the connector gates.

The point of this server is to be a PEER THAT CHECKS, like
scripts/mqtt_test_broker.py: the gate asserts what the server saw, not what the
client believed it sent. Two behaviours matter here:

  * `--require NAME=VALUE` makes the server answer 404 unless the request carries
    that header, with a PostgREST-shaped error body. This is how a real
    PostgREST deployment behaves when `Accept-Profile` is missing — measured
    against https://zh-sw.citicenvirotech.com/pgrest/ (no header: 404 "Could not
    find the table 'public.inlet_node_value' in the schema cache").
  * `--log FILE` appends one JSON line per request with the method, path and the
    headers that arrived, so a gate can prove the request really carried them.

Stdlib only, no dependencies.
"""

from __future__ import annotations

import argparse
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _log_request(self) -> None:
        if not self.server.log_path:
            return
        record = {
            "method": self.command,
            "path": self.path,
            "headers": {name: value for name, value in self.headers.items()},
        }
        with open(self.server.log_path, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(record, ensure_ascii=False) + "\n")

    def _maybe_fail(self) -> bool:
        """A server that is briefly broken, for the retry gate: the first N
        requests answer 500 and are counted, so a client that gives up on them
        never sees the healthy server behind them."""
        with self.server.lock:
            if self.server.served < self.server.fail_first:
                self.server.served += 1
                self.send_response(500)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return True
            self.server.served += 1
        return False

    def do_GET(self) -> None:  # noqa: N802 (stdlib naming)
        self._log_request()
        if self._maybe_fail():
            return
        for name, value in self.server.required:
            if self.headers.get(name) != value:
                body = json.dumps({
                    "code": "PGRST205",
                    "message": (
                        f"Could not find the table 'public.{self.path.strip('/')}' "
                        "in the schema cache"
                    ),
                    "hint": f"missing or wrong header {name}",
                }).encode("utf-8")
                self.send_response(404)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
        with open(self.server.body_path, "rb") as fh:
            body = fh.read()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self) -> None:  # noqa: N802
        length = int(self.headers.get("Content-Length", "0"))
        received = self.rfile.read(length) if length else b""
        self._log_request()
        if self._maybe_fail():
            return
        for name, value in self.server.required:
            if self.headers.get(name) != value:
                self.send_response(404)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
        # POST bodies go to their own file: appending them to --body would
        # corrupt the GET response a later request is supposed to get (measured
        # while wiring the alert relay).
        if self.server.post_log:
            with open(self.server.post_log, "ab") as fh:
                fh.write(received)
        self.send_response(200)
        self.send_header("Content-Length", "2")
        self.end_headers()
        self.wfile.write(b"ok")

    def log_message(self, *_args) -> None:
        pass  # the gate reads the JSON log, not stderr chatter


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--body", required=True, help="file whose bytes are the 200 response")
    parser.add_argument("--log", help="JSONL file recording every request")
    parser.add_argument("--require", action="append", default=[],
                        help="NAME=VALUE that must appear or the answer is 404")
    parser.add_argument("--tls-cert", help="PEM certificate: serve https instead of http")
    parser.add_argument("--tls-key", help="PEM private key for --tls-cert")
    parser.add_argument("--sni-name", help="name that selects --sni-cert instead of --tls-cert")
    parser.add_argument("--sni-cert", help="the certificate served when SNI matches --sni-name")
    parser.add_argument("--sni-key", help="key for --sni-cert")
    parser.add_argument("--post-log", help="JSONL file recording each POST body")
    parser.add_argument("--fail-first", type=int, default=0,
                        help="answer 500 to the first N GET/POST requests (retry gates)")
    parser.add_argument("--require-sni", metavar="NAME",
                        help="refuse the handshake unless SNI carries NAME")
    args = parser.parse_args()

    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    server.body_path = args.body
    server.log_path = args.log
    server.post_log = args.post_log
    server.fail_first = args.fail_first
    server.served = 0
    import threading
    server.lock = threading.Lock()
    server.required = []
    for item in args.require:
        if "=" not in item:
            print(f"--require needs NAME=VALUE, got {item!r}", file=sys.stderr)
            return 2
        name, value = item.split("=", 1)
        server.required.append((name, value))
    scheme = "http"
    if args.tls_cert:
        import ssl
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(args.tls_cert, args.tls_key)
        if args.require_sni:
            # A client that does not send SNI (or sends the wrong name) is
            # REFUSED at the handshake. That makes "the connection succeeded" a
            # proof that the name really went out — the shape
            # `openssl s_server -servername` would give, which LibreSSL's
            # s_server does not support (measured: it printed usage for -cert2).
            def require(_sock, server_name, _ctx):
                with open(server.log_path or "/dev/null", "a", encoding="utf-8") as fh:
                    fh.write(json.dumps({"sni": server_name}, ensure_ascii=False) + "\n")
                if server_name != args.require_sni:
                    raise ValueError(f"SNI {server_name!r} is not {args.require_sni!r}")

            context.sni_callback = require

        if args.sni_name:
            # The DEFAULT certificate stays args.tls_cert (deliberately the
            # wrong one for this job): a client that does not send SNI is served
            # it, and verification fails. Only a client that NAMES the host gets
            # the certificate that can verify — which is the whole point of a
            # multi-vhost server, and the reason a single-certificate fixture
            # cannot see a client that never sends SNI.
            def pick(_sock, server_name, ctx, _cert=args.sni_cert, _key=args.sni_key):
                # Record what the peer actually named, so a gate can assert the
                # SERVER's view rather than the client's intention, and swap the
                # certificate IN PLACE. Returning an SSLContext from this
                # callback is not supported by CPython's ssl module: it surfaces
                # as "TypeError: 'SSLContext' object cannot be interpreted as an
                # integer" during the handshake, i.e. a TLS alert internal error
                # at the client (measured).
                with open(server.log_path or "/dev/null", "a", encoding="utf-8") as fh:
                    fh.write(json.dumps({"sni": server_name}, ensure_ascii=False) + "\n")
                # signature is (socket, name, context): the context is the
                # THIRD argument, and swapping its certificate in place is the
                # supported way to answer SNI (measured the hard way — using the
                # first argument gives "'SSLSocket' object has no attribute
                # 'load_cert_chain'", and returning a context gives a TypeError
                # during the handshake)
                if server_name == args.sni_name:
                    ctx.load_cert_chain(_cert, _key)
                return None

            context.sni_callback = pick
        server.socket = context.wrap_socket(server.socket, server_side=True)
        scheme = "https"
    print(f"fixture server on {scheme}://127.0.0.1:{args.port} "
          f"(required: {server.required or 'nothing'})", flush=True)
    server.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
