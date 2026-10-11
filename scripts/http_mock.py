#!/usr/bin/env python3
"""A tiny HTTP peer for the callout gate (P30/T115).

Same discipline as scripts/mqtt_test_broker.py and the Kafka probe: the gate
asserts what the SERVER saw, not what the client intended. Every request is
appended to a log file as one JSON line (method, path, headers, body), so a
leg can grep for the Authorization header it sent, the URL template it
filled, and the body it built.

Endpoints:
  GET  /api/maker/<name>   -> the reference's maker payload
  POST /v1/chat            -> a canned chat completion body
  GET  /stall              -> sleeps forever (the deadline leg)
  anything else            -> 404

Usage: http_mock.py --port N --log /path/to/requests.jsonl
"""
import argparse
import json
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MAKERS = {
    "Fiat": {"maker": "Fiat", "country": "Italy", "continent": "Europe"},
    "Toyota": {"maker": "Toyota", "country": "Japan", "continent": "Asia"},
    "Ford": {"maker": "Ford", "country": "United States", "continent": "North America"},
    "Tesla": {"maker": "Tesla", "country": "United States", "continent": "North America"},
}
LOG_PATH = None


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_args):
        pass  # the log file is the record, not stderr

    def _record(self, body):
        if LOG_PATH is None:
            return
        entry = {
            "method": self.command,
            "path": self.path,
            "headers": {k.lower(): v for k, v in self.headers.items()},
            "body": body.decode("utf-8", "replace"),
        }
        with open(LOG_PATH, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(entry) + "\n")
            fh.flush()

    def _send(self, status, payload):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self._record(b"")
        if self.path.startswith("/api/maker/"):
            name = self.path[len("/api/maker/"):]
            name = name.replace("%20", " ")
            maker = MAKERS.get(name)
            if maker is None:
                self._send(404, {"error": "unknown maker", "maker": name})
                return
            self._send(200, maker)
            return
        if self.path.startswith("/stall"):
            # hold the connection open: the caller's deadline is the point
            time.sleep(30)
            self._send(200, {"stalled": True})
            return
        self._send(404, {"error": "no such endpoint", "path": self.path})

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length) if length else b""
        self._record(body)
        if self.path.startswith("/v1/chat"):
            try:
                request = json.loads(body.decode("utf-8", "replace"))
            except Exception:
                request = {}
            model = request.get("model", "gpt-3.5-turbo")
            self._send(200, {"model": model, "output": "hello from the mock"})
            return
        self._send(404, {"error": "no such endpoint", "path": self.path})


def main():
    global LOG_PATH
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--log", required=True)
    args = parser.parse_args()
    LOG_PATH = args.log
    open(LOG_PATH, "w").close()
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print(f"http mock listening on 127.0.0.1:{args.port}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    sys.exit(main())
