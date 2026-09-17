#!/usr/bin/env python3
"""An independent MFS client, in Python (P12).

Why this exists: the security gate has to prove that a *client* identity
cannot issue a node command (a forged REGISTER or SYNC_ACK moves the high
watermark every committed read is built on). The moonflux CLI cannot send
a command it does not believe in, so the assertion would be about the CLI
rather than about the server. This probe writes the frames itself — which
also makes it a second, independent implementation of the wire format,
the same "crosscheck from outside" stance the protocol gate takes.

Frame (v2), big-endian:

    "MFS" | version(1) | cmd(1) | rid(u32) | length(u32) | payload

Field (a string inside a payload): uleb128 length | utf-8 bytes.
Integer: uleb128.

Usage:
    mfs_probe.py <host:port> --cmd N [--token T] [--payload hex|node:ID:ROLE:ADDR:LEO]
                 [--json] [--tls-ca CA [--tls-cert C --tls-key K]]
"""

import argparse
import socket
import ssl
import sys

MAGIC = b"MFS"
VERSION = 2

CMD_HELLO = 1
CMD_WELCOME = 2
CMD_ERR = 6
CMD_REGISTER = 7
CMD_AUTH = 35


def uleb128(value: int) -> bytes:
    out = bytearray()
    while True:
        byte = value & 0x7F
        value >>= 7
        if value:
            out.append(byte | 0x80)
        else:
            out.append(byte)
            return bytes(out)


def read_uleb128(data: bytes, offset: int) -> tuple[int, int]:
    result = 0
    shift = 0
    while True:
        if offset >= len(data):
            raise ValueError("truncated uleb128")
        byte = data[offset]
        offset += 1
        result |= (byte & 0x7F) << shift
        if not byte & 0x80:
            return result, offset
        shift += 7


def frame(cmd: int, rid: int, payload: bytes = b"") -> bytes:
    return (
        MAGIC
        + bytes([VERSION, cmd])
        + rid.to_bytes(4, "big")
        + len(payload).to_bytes(4, "big")
        + payload
    )


def field(text: str) -> bytes:
    raw = text.encode()
    return uleb128(len(raw)) + raw


def node_record(node_id: str, role: str, address: str, leo: int = 0) -> bytes:
    """The node report as `encode_node_full` writes it, with no
    per-partition section (the optional tail)."""
    return field(node_id) + field(role) + field(address) + uleb128(leo) + uleb128(0)


def recv_frame(sock) -> tuple[int, bytes]:
    header = b""
    while len(header) < 13:
        chunk = sock.recv(13 - len(header))
        if not chunk:
            raise EOFError("peer closed before a reply")
        header += chunk
    if header[0:3] != MAGIC:
        raise ValueError(f"bad frame magic: {header[0:3]!r}")
    cmd = header[4]
    length = int.from_bytes(header[9:13], "big")
    payload = b""
    while len(payload) < length:
        chunk = sock.recv(length - len(payload))
        if not chunk:
            raise EOFError("peer closed mid-payload")
        payload += chunk
    return cmd, payload


def decode_error(payload: bytes) -> tuple[int, str]:
    code = int.from_bytes(payload[0:4], "big")
    return code, payload[4:].decode(errors="replace")


def connect(addr: str, tls_ca: str | None, tls_cert: str | None, tls_key: str | None):
    host, port_text = addr.rsplit(":", 1)
    raw = socket.create_connection((host, int(port_text)), timeout=5)
    if tls_ca is None:
        return raw
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.load_verify_locations(tls_ca)
    context.check_hostname = True
    if tls_cert:
        context.load_cert_chain(tls_cert, tls_key)
    return context.wrap_socket(raw, server_hostname=host)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("addr")
    parser.add_argument("--cmd", type=int, required=True)
    parser.add_argument("--rid", type=int, default=1)
    parser.add_argument("--token")
    parser.add_argument(
        "--payload",
        default="",
        help="hex bytes, or node:ID:ROLE:LEO:ADDR for a node report",
    )
    parser.add_argument("--raw-reply", action="store_true",
                        help="print the reply payload as hex")
    parser.add_argument("--tls-ca")
    parser.add_argument("--tls-cert")
    parser.add_argument("--tls-key")
    args = parser.parse_args()

    if args.payload.startswith("node:"):
        _, node_id, role, leo, address = args.payload.split(":", 4)
        payload = node_record(node_id, role, address, int(leo))
    elif args.payload:
        payload = bytes.fromhex(args.payload)
    else:
        payload = b""

    try:
        sock = connect(args.addr, args.tls_ca, args.tls_cert, args.tls_key)
    except (OSError, ssl.SSLError) as error:
        print(f"connect: {error}")
        return 2

    try:
        sock.sendall(frame(CMD_HELLO, 0, (1).to_bytes(4, "big") + (0).to_bytes(4, "big")))
        cmd, reply = recv_frame(sock)
        if cmd != CMD_WELCOME:
            if cmd == CMD_ERR:
                code, message = decode_error(reply)
                print(f"refused during handshake (code {code}): {message}")
            else:
                print(f"unexpected handshake reply: cmd {cmd}")
            return 3
        if args.token is not None:
            sock.sendall(frame(CMD_AUTH, 0, args.token.encode()))
            cmd, reply = recv_frame(sock)
            if cmd == CMD_ERR:
                code, message = decode_error(reply)
                print(f"REFUSED-AUTH {code}: {message}")
                return 4
        sock.sendall(frame(args.cmd, args.rid, payload))
        cmd, reply = recv_frame(sock)
    except (EOFError, ValueError, OSError) as error:
        print(f"protocol: {error}")
        return 5
    finally:
        sock.close()

    if cmd == CMD_ERR:
        code, message = decode_error(reply)
        print(f"REFUSED {code}: {message}")
        return 10
    if args.raw_reply:
        print(f"OK cmd={cmd} payload={reply.hex()}")
    else:
        print(f"ACCEPTED cmd={cmd} payload={reply.decode(errors='replace')}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
