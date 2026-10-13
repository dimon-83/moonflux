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

    def do_GET(self) -> None:  # noqa: N802 (stdlib naming)
        self._log_request()
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
        with open(self.server.body_path, "ab") as fh:
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
    args = parser.parse_args()

    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    server.body_path = args.body
    server.log_path = args.log
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
        server.socket = context.wrap_socket(server.socket, server_side=True)
        scheme = "https"
    print(f"fixture server on {scheme}://127.0.0.1:{args.port} "
          f"(required: {server.required or 'nothing'})", flush=True)
    server.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
