#!/usr/bin/env python3
"""Client shapes for the P5 concurrency gate.

A gate about "nothing starves anyone" needs peers that *stay*: an idle
browser connection, a peer that connects and says nothing, one that
sends half a frame and stalls, and one that runs a real session. Each
mode below is one of those; the gate runs them against a live broker.

Usage: python3 p5_hold_ws.py <port> <mode>

Modes:
  open     upgrade to WebSocket, print "holding", then stay connected
           (and idle) until killed — the shape that used to starve the
           server's single connection slot
  silent   connect and send nothing at all
  partial  send two bytes of a frame header, then stall
  session  run a real HELLO -> PRODUCE -> FETCH over WebSocket and print
           "websocket session ok"
"""

import base64
import hashlib
import os
import socket
import struct
import sys
import time


def upgrade(sock, port):
    key = base64.b64encode(os.urandom(16)).decode()
    sock.sendall(
        (
            "GET / HTTP/1.1\r\nHost: 127.0.0.1:%d\r\nUpgrade: websocket\r\n"
            "Connection: Upgrade\r\nSec-WebSocket-Key: %s\r\n"
            "Sec-WebSocket-Version: 13\r\n\r\n" % (port, key)
        ).encode()
    )
    head = b""
    while b"\r\n\r\n" not in head:
        chunk = sock.recv(1)
        if not chunk:
            raise SystemExit("handshake closed early")
        head += chunk
    expected = base64.b64encode(
        hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()
    ).decode()
    if ("Sec-WebSocket-Accept: %s" % expected) not in head.decode(errors="replace"):
        raise SystemExit("accept key mismatch")


def send_ws(sock, opcode, payload):
    mask = os.urandom(4)
    header = bytes([0x80 | opcode])
    n = len(payload)
    if n < 126:
        header += bytes([0x80 | n])
    elif n <= 65535:
        header += bytes([0x80 | 126]) + struct.pack(">H", n)
    else:
        header += bytes([0x80 | 127]) + struct.pack(">Q", n)
    sock.sendall(header + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(payload)))


def recv_exact(sock, n):
    out = b""
    while len(out) < n:
        chunk = sock.recv(n - len(out))
        if not chunk:
            raise SystemExit("closed mid-frame")
        out += chunk
    return out


def recv_ws(sock):
    h = recv_exact(sock, 2)
    opcode = h[0] & 0x0F
    length = h[1] & 0x7F
    if length == 126:
        length = struct.unpack(">H", recv_exact(sock, 2))[0]
    elif length == 127:
        length = struct.unpack(">Q", recv_exact(sock, 8))[0]
    return opcode, recv_exact(sock, length)


def mfs(cmd, rid, payload=b""):
    return b"MFS" + bytes([2, cmd]) + struct.pack(">II", rid, len(payload)) + payload


def uleb(n):
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        out.append(b | (0x80 if n else 0))
        if not n:
            break
    return bytes(out)


def main():
    port = int(sys.argv[1])
    mode = sys.argv[2]
    sock = socket.create_connection(("127.0.0.1", port), timeout=10)
    if mode == "silent":
        print("silent peer connected", flush=True)
        # stay connected, never send
        while True:
            time.sleep(1)
    if mode == "partial":
        print("sending half a frame header, then stalling", flush=True)
        sock.sendall(b"MF")  # two bytes of a 13-byte header
        while True:
            time.sleep(1)
    upgrade(sock, port)
    if mode == "open":
        print("holding", flush=True)
        while True:
            time.sleep(1)
    if mode == "session":
        send_ws(sock, 2, mfs(1, 0, struct.pack(">II", 1, 0)))
        opcode, payload = recv_ws(sock)
        if payload[4] != 2:
            raise SystemExit("expected WELCOME, got %d" % payload[4])
        topic = b"p5ws"
        # one record: uleb key/value lengths
        def record(key, value):
            body = struct.pack(">q", 0) + uleb(len(key)) + key + uleb(len(value)) + value + uleb(0)
            return uleb(len(body)) + body
        blob = record(b"", b"from-websocket")
        # the batch header's count and length are u32 big-endian (only
        # the per-record lengths are varints) — a varint here is what
        # "MalformedLength" means
        import zlib
        counts = struct.pack(">I", 1) + struct.pack(">I", len(blob))
        crc = zlib.crc32(counts + blob) & 0xFFFFFFFF
        body_len = 8 + 4 + len(counts) + len(blob)
        frame = (
            b"MFB" + bytes([1]) + struct.pack(">I", body_len)
            + struct.pack(">q", -1) + struct.pack(">I", crc) + counts + blob
        )
        send_ws(sock, 2, mfs(3, 1, uleb(len(topic)) + topic + frame))
        opcode, payload = recv_ws(sock)
        if payload[4] != 5:
            raise SystemExit("produce failed: %r" % payload[:40])
        send_ws(sock, 2, mfs(4, 2, uleb(len(topic)) + topic + struct.pack(">qI", 0, 100)))
        opcode, payload = recv_ws(sock)
        if payload[4] != 5:
            raise SystemExit("fetch failed: %r" % payload[:40])
        print("websocket session ok", flush=True)
        sock.close()
        return
    raise SystemExit("unknown mode %s" % mode)


if __name__ == "__main__":
    main()
