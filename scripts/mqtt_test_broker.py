#!/usr/bin/env python3
"""A minimal MQTT 3.1.1 broker — the P19 gate's independent peer.

Deliberately not a library and not a mirror of the client: the gate's
job is to assert against bytes on the wire, so this speaks the protocol
straight from the specification (CONNECT/CONNACK, SUBSCRIBE/SUBACK,
PUBLISH both ways, PINGREQ/PINGRESP), records what it saw, and pushes
the messages it was told to push. Same spirit as mfs_probe.py: an
independent second implementation is what makes the assertions about
the *server side* rather than about the client's intentions.

Usage:
  mqtt_test_broker.py --listen 127.0.0.1:19801 \
      --publish sensors:alpha --publish sensors:beta \
      --facts broker.facts            # connect/subscribe facts, appended
      --received received.txt         # payloads published *to* the broker
      [--refuse]                      # refuse CONNECT (rc=5)

Each connection runs in its own thread: the source and sink under test
are separate MQTT sessions, and a single-threaded fixture would make
the second one wait for the first to disconnect — which never happens
to a subscription.
"""
import argparse
import socket
import struct
import sys
import threading

TYPE_CONNECT = 1
TYPE_CONNACK = 2
TYPE_PUBLISH = 3
TYPE_PUBACK = 4
TYPE_SUBSCRIBE = 8
TYPE_SUBACK = 9
TYPE_PINGREQ = 12
TYPE_PINGRESP = 13
TYPE_DISCONNECT = 14


def read_exact(conn, n):
    out = b""
    while len(out) < n:
        chunk = conn.recv(n - len(out))
        if not chunk:
            raise ConnectionError("closed mid-packet")
        out += chunk
    return out


def read_packet(conn):
    """One control packet: (type_flags, body)."""
    first = read_exact(conn, 1)[0]
    remaining = 0
    multiplier = 1
    while True:
        digit = read_exact(conn, 1)[0]
        remaining += (digit & 0x7F) * multiplier
        multiplier *= 128
        if not digit & 0x80:
            break
    return first, read_exact(conn, remaining)


def encode_remaining_length(n):
    out = b""
    while True:
        digit = n % 128
        n //= 128
        if n:
            digit |= 0x80
        out += bytes([digit])
        if not n:
            return out


def packet(type_flags, body):
    return bytes([type_flags]) + encode_remaining_length(len(body)) + body


def mqtt_string(text):
    raw = text.encode("utf-8")
    return struct.pack(">H", len(raw)) + raw


def read_mqtt_string(body, at):
    length = struct.unpack(">H", body[at : at + 2])[0]
    text = body[at + 2 : at + 2 + length].decode("utf-8", "replace")
    return text, at + 2 + length


class Broker:
    def __init__(self, publishes, facts_path, received_path, refuse):
        self.publishes = publishes  # [(topic, payload bytes)]
        self.facts_path = facts_path
        self.received_path = received_path
        self.refuse = refuse
        self.lock = threading.Lock()

    def fact(self, line):
        if self.facts_path:
            with self.lock, open(self.facts_path, "a") as fh:
                fh.write(line + "\n")
                fh.flush()

    def received(self, payload):
        if self.received_path:
            with self.lock, open(self.received_path, "a") as fh:
                fh.write(payload.decode("utf-8", "replace") + "\n")
                fh.flush()

    def handle(self, conn):
        try:
            type_flags, body = read_packet(conn)
            if type_flags >> 4 != TYPE_CONNECT:
                self.fact("unexpected packet %d before CONNECT" % (type_flags >> 4))
                return
            name, at = read_mqtt_string(body, 0)
            level = body[at]
            flags = body[at + 1]
            at += 2
            keepalive = struct.unpack(">H", body[at : at + 2])[0]
            at += 2
            client_id, at = read_mqtt_string(body, at)
            user = "-"
            if flags & 0x80:
                user, at = read_mqtt_string(body, at)
            self.fact(
                "connect client_id=%s name=%s level=%d clean=%d keepalive=%d user=%s"
                % (client_id, name, level, 1 if flags & 0x02 else 0, keepalive, user)
            )
            if self.refuse:
                conn.sendall(packet(TYPE_CONNACK << 4, bytes([0, 5])))  # not authorized
                return
            conn.sendall(packet(TYPE_CONNACK << 4, bytes([0, 0])))
            while True:
                type_flags, body = read_packet(conn)
                kind = type_flags >> 4
                if kind == TYPE_SUBSCRIBE:
                    packet_id = body[0:2]
                    topic, _ = read_mqtt_string(body, 2)
                    self.fact("subscribe topic=%s" % topic)
                    conn.sendall(
                        packet(TYPE_SUBACK << 4, packet_id + bytes([0]))
                    )
                    for pub_topic, payload in self.publishes:
                        if pub_topic == topic:
                            conn.sendall(
                                packet(
                                    TYPE_PUBLISH << 4,
                                    mqtt_string(topic) + payload,
                                )
                            )
                elif kind == TYPE_PUBLISH:
                    qos = (type_flags >> 1) & 0x03
                    topic, at = read_mqtt_string(body, 0)
                    if qos > 0:
                        packet_id = body[at : at + 2]
                        at += 2
                        conn.sendall(packet(TYPE_PUBACK << 4, packet_id))
                    self.fact("publish topic=%s" % topic)
                    self.received(body[at:])
                elif kind == TYPE_PINGREQ:
                    conn.sendall(packet(TYPE_PINGRESP << 4, b""))
                elif kind == TYPE_DISCONNECT:
                    return
                # anything else: ignore, like a broker with more features
        except (ConnectionError, OSError):
            return
        finally:
            conn.close()

    def serve(self, host, port):
        listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind((host, port))
        listener.listen(8)
        print("mqtt test broker listening on %s:%d" % (host, port), flush=True)
        while True:
            conn, _ = listener.accept()
            threading.Thread(target=self.handle, args=(conn,), daemon=True).start()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--listen", required=True, help="host:port")
    ap.add_argument(
        "--publish",
        action="append",
        default=[],
        help="topic:payload to push on SUBSCRIBE (repeatable)",
    )
    ap.add_argument("--facts", default=None)
    ap.add_argument("--received", default=None)
    ap.add_argument("--refuse", action="store_true")
    args = ap.parse_args()
    host, port = args.listen.rsplit(":", 1)
    publishes = []
    for item in args.publish:
        topic, payload = item.split(":", 1)
        publishes.append((topic, payload.encode("utf-8")))
    Broker(publishes, args.facts, args.received, args.refuse).serve(host, int(port))


if __name__ == "__main__":
    sys.exit(main())
