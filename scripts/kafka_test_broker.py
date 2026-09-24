#!/usr/bin/env python3
"""A minimal Kafka broker — the P20 gate's independent peer.

Deliberately not a library: the gate's job is to assert against bytes on
the wire, so this speaks the pinned protocol versions straight from the
Kafka definitions (ApiVersions v0, Metadata v1, ListOffsets v1,
Produce v3, Fetch v4), **verifies the CRC-32C of every record batch it
is handed and parses the records**, assigns offsets, and serves them
back. Same spirit as mfs_probe.py and mqtt_test_broker.py: the
assertions are about the server side of the wire, not about what the
client believes it sent.

CRC-32C is re-implemented here from the polynomial and pinned by the
standard check value at startup — two hand-rolled implementations must
not agree by sharing a mistake.

Usage:
  kafka_test_broker.py --listen 127.0.0.1:19901 --topic events \
      --facts broker.facts --received received.txt \
      [--produce-version-max N]   # advertise a lower Produce ceiling
"""
import argparse
import socket
import struct
import sys
import threading

API_PRODUCE = 0
API_FETCH = 1
API_LIST_OFFSETS = 2
API_METADATA = 3
API_API_VERSIONS = 18

NODE_ID = 1

# ---------------------------------------------------------------------------
# CRC-32C (Castagnoli), table-driven — the anchor that keeps this peer
# and the MoonBit client from agreeing on the same wrong polynomial.

def _build_table():
    table = []
    for i in range(256):
        c = i
        for _ in range(8):
            c = (0x82F63B78 ^ (c >> 1)) if (c & 1) else (c >> 1)
        table.append(c)
    return table


_CRC32C_TABLE = _build_table()


def crc32c(data):
    c = 0xFFFFFFFF
    for byte in data:
        c = _CRC32C_TABLE[(c ^ byte) & 0xFF] ^ (c >> 8)
    return c ^ 0xFFFFFFFF


assert crc32c(b"123456789") == 0xE3069283, "CRC-32C self-check failed"


# ---------------------------------------------------------------------------
# Wire primitives

class Reader:
    def __init__(self, data):
        self.data = data
        self.pos = 0

    def take(self, n):
        if self.pos + n > len(self.data):
            raise ValueError("truncated")
        out = self.data[self.pos:self.pos + n]
        self.pos += n
        return out

    def i16(self):
        return struct.unpack(">h", self.take(2))[0]

    def i32(self):
        return struct.unpack(">i", self.take(4))[0]

    def i64(self):
        return struct.unpack(">q", self.take(8))[0]

    def u8(self):
        return self.take(1)[0]

    def string(self):
        n = self.i16()
        if n < 0:
            return None
        return self.take(n).decode("utf-8", "replace")

    def bytes_field(self):
        n = self.i32()
        if n < 0:
            return b""
        return self.take(n)

    def remaining(self):
        return len(self.data) - self.pos


def w_i16(v):
    return struct.pack(">h", v)


def w_i32(v):
    return struct.pack(">i", v)


def w_i64(v):
    return struct.pack(">q", v)


def w_string(s):
    if s is None:
        return w_i16(-1)
    raw = s.encode("utf-8")
    return w_i16(len(raw)) + raw


def w_bytes(b):
    return w_i32(len(b)) + b


def read_frame(conn):
    head = conn.recv(4)
    while len(head) < 4:
        more = conn.recv(4 - len(head))
        if not more:
            raise ConnectionError("closed")
        head += more
    size = struct.unpack(">i", head)[0]
    body = b""
    while len(body) < size:
        more = conn.recv(size - len(body))
        if not more:
            raise ConnectionError("closed mid-frame")
        body += more
    return body


def zigzag_decode(value):
    return (value >> 1) ^ -(value & 1)


def read_varint(reader):
    shift = 0
    value = 0
    while True:
        digit = reader.u8()
        value |= (digit & 0x7F) << shift
        if not digit & 0x80:
            return value
        shift += 7


# ---------------------------------------------------------------------------
# RecordBatch v2 parsing (the broker verifies what it is handed)

def parse_batch(blob):
    """Returns (base_offset, [{"key","value","timestamp"}]) or raises."""
    if len(blob) < 61:
        raise ValueError("batch shorter than its header")
    base = struct.unpack(">q", blob[0:8])[0]
    batch_len = struct.unpack(">i", blob[8:12])[0]
    magic = blob[16]
    crc = struct.unpack(">I", blob[17:21])[0]
    if magic != 2:
        raise ValueError("magic %d" % magic)
    if 12 + batch_len != len(blob):
        raise ValueError("batch length %d does not match %d bytes"
                         % (batch_len, len(blob)))
    covered = blob[21:]
    if crc32c(covered) != crc:
        raise ValueError("CRC-32C mismatch")
    r = Reader(covered)
    attrs = r.i16()
    if attrs & 0x07:
        raise ValueError("compressed batch (codec %d)" % (attrs & 0x07))
    _last_offset_delta = r.i32()
    first_ts = r.i64()
    _max_ts = r.i64()
    _producer_id = r.i64()
    _producer_epoch = r.i16()
    _base_sequence = r.i32()
    count = r.i32()
    records = []
    for _ in range(count):
        rlen = zigzag_decode(read_varint(r))
        end = r.pos + rlen
        _attrs = r.u8()
        ts_delta = zigzag_decode(read_varint(r))
        _offset_delta = zigzag_decode(read_varint(r))
        klen = zigzag_decode(read_varint(r))
        key = b"" if klen < 0 else r.take(klen)
        vlen = zigzag_decode(read_varint(r))
        value = b"" if vlen < 0 else r.take(vlen)
        hcount = zigzag_decode(read_varint(r))
        for _ in range(hcount):
            hklen = zigzag_decode(read_varint(r))
            if hklen > 0:
                r.take(hklen)
            hvlen = zigzag_decode(read_varint(r))
            if hvlen > 0:
                r.take(hvlen)
        r.pos = end  # the record's own length is authoritative
        records.append({
            "key": key,
            "value": value,
            "timestamp": first_ts + ts_delta,
        })
    return base, records


class Partition:
    def __init__(self):
        self.next_offset = 0
        self.batches = []  # (base_offset, blob with the base patched in)


class Broker:
    def __init__(self, host, port, topic, facts_path, received_path,
                 produce_version_max, dump_path=None):
        self.host = host
        self.port = port
        self.topic = topic
        self.facts_path = facts_path
        self.received_path = received_path
        self.produce_version_max = produce_version_max
        self.dump_path = dump_path
        self.lock = threading.Lock()
        self.partition = Partition()

    def fact(self, line):
        if self.facts_path:
            with self.lock, open(self.facts_path, "a") as fh:
                fh.write(line + "\n")
                fh.flush()

    def received(self, record):
        if self.received_path:
            key = record["key"].decode("utf-8", "replace")
            value = record["value"].decode("utf-8", "replace")
            with self.lock, open(self.received_path, "a") as fh:
                fh.write("%s\t%s\n" % (key, value))
                fh.flush()

    # -- individual APIs ---------------------------------------------------

    def api_versions(self, correlation):
        declared = [
            (API_PRODUCE, 3, self.produce_version_max),
            (API_FETCH, 4, 4),
            (API_LIST_OFFSETS, 1, 1),
            (API_METADATA, 1, 1),
            (API_API_VERSIONS, 0, 0),
        ]
        body = w_i16(0) + w_i32(len(declared))
        for key, lo, hi in declared:
            body += w_i16(key) + w_i16(lo) + w_i16(hi)
        return body

    def metadata(self, correlation):
        body = w_i32(1)  # one broker
        body += w_i32(NODE_ID) + w_string(self.host) + w_i32(self.port)
        body += w_string(None)  # rack
        body += w_i32(NODE_ID)  # controller
        body += w_i32(1)  # one topic
        body += w_i16(0) + w_string(self.topic) + bytes([0])  # error, name, is_internal
        body += w_i32(1)  # one partition
        body += w_i16(0) + w_i32(0) + w_i32(NODE_ID)  # error, index, leader
        body += w_i32(1) + w_i32(NODE_ID)  # replicas
        body += w_i32(1) + w_i32(NODE_ID)  # isr
        return body

    def list_offsets(self, correlation, reader):
        reader.i32()  # replica_id
        topics = reader.i32()
        body = w_i32(topics)
        for _ in range(topics):
            name = reader.string()
            body += w_string(name)
            parts = reader.i32()
            body += w_i32(parts)
            for _ in range(parts):
                index = reader.i32()
                timestamp = reader.i64()
                with self.lock:
                    if timestamp == -2:  # earliest
                        offset = self.partition.batches[0][0] if self.partition.batches else 0
                    elif timestamp == -1:  # latest
                        offset = self.partition.next_offset
                    else:
                        offset = timestamp
                body += w_i32(index) + w_i16(0) + w_i64(timestamp) + w_i64(offset)
        return body

    def produce(self, correlation, reader):
        transactional_id = reader.string()
        acks = reader.i16()
        _timeout = reader.i32()
        topics = reader.i32()
        responses = []
        for _ in range(topics):
            name = reader.string()
            parts = reader.i32()
            for _ in range(parts):
                index = reader.i32()
                blob = reader.bytes_field()
                base, records = parse_batch(blob)  # raises on bad CRC/shape
                with self.lock:
                    assigned = self.partition.next_offset
                    # the base offset is outside the CRC on purpose: the
                    # broker assigns it by rewriting eight bytes
                    patched = struct.pack(">q", assigned) + blob[8:]
                    self.partition.batches.append((assigned, patched))
                    self.partition.next_offset += len(records)
                for record in records:
                    self.received(record)
                self.fact(
                    "produce topic=%s partition=%d acks=%d records=%d base=%d crc=ok"
                    % (name, index, acks, len(records), assigned)
                )
                responses.append((name, index, 0, assigned))
        # group by topic (there is exactly one in this fixture)
        grouped = {}
        for name, index, error, base in responses:
            grouped.setdefault(name, []).append((index, error, base))
        body = w_i32(len(grouped))
        for name, parts in grouped.items():
            body += w_string(name) + w_i32(len(parts))
            for index, error, base in parts:
                body += w_i32(index) + w_i16(error) + w_i64(base) + w_i64(-1)
        body += w_i32(0)  # throttle
        return body

    def fetch(self, correlation, reader):
        reader.i32()  # replica_id
        reader.i32()  # max_wait_ms
        reader.i32()  # min_bytes
        reader.i32()  # max_bytes
        reader.u8()  # isolation_level
        topics = reader.i32()
        body = w_i32(0)  # throttle
        body += w_i32(topics)
        for _ in range(topics):
            name = reader.string()
            body += w_string(name)
            parts = reader.i32()
            body += w_i32(parts)
            for _ in range(parts):
                index = reader.i32()
                fetch_offset = reader.i64()
                reader.i32()  # partition_max_bytes
                with self.lock:
                    hw = self.partition.next_offset
                    served = b"".join(
                        blob for base, blob in self.partition.batches
                        if base >= fetch_offset
                    )
                body += w_i32(index) + w_i16(0) + w_i64(hw) + w_i64(hw)
                body += w_i32(-1)  # aborted_transactions: null
                body += w_bytes(served)
        return body

    # -- the loop ----------------------------------------------------------

    def handle(self, conn):
        try:
            while True:
                frame = read_frame(conn)
                if self.dump_path:
                    # development-time evidence: every raw request frame,
                    # size-prefixed, for a third-party decoder to parse
                    with self.lock, open(self.dump_path, "ab") as fh:
                        fh.write(struct.pack(">i", len(frame)) + frame)
                reader = Reader(frame)
                api_key = reader.i16()
                api_version = reader.i16()
                correlation = reader.i32()
                client_id = reader.string()
                if api_key == API_API_VERSIONS:
                    self.fact("apiversions client_id=%s" % client_id)
                    body = self.api_versions(correlation)
                elif api_key == API_METADATA:
                    reader.i32()  # topics array count
                    topic = reader.string()
                    self.fact("metadata topic=%s" % topic)
                    body = self.metadata(correlation)
                elif api_key == API_LIST_OFFSETS:
                    body = self.list_offsets(correlation, reader)
                elif api_key == API_PRODUCE:
                    body = self.produce(correlation, reader)
                elif api_key == API_FETCH:
                    body = self.fetch(correlation, reader)
                else:
                    raise ValueError("unexpected api key %d" % api_key)
                conn.sendall(w_i32(4 + len(body)) + w_i32(correlation) + body)
        except (ConnectionError, OSError, ValueError) as e:
            self.fact("error %s" % e)
            conn.close()
            return

    def serve(self):
        listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind((self.host, self.port))
        listener.listen(8)
        print("kafka test broker listening on %s:%d" % (self.host, self.port),
              flush=True)
        while True:
            conn, _ = listener.accept()
            threading.Thread(target=self.handle, args=(conn,), daemon=True).start()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--listen", required=True, help="host:port")
    ap.add_argument("--topic", required=True)
    ap.add_argument("--facts", default=None)
    ap.add_argument("--received", default=None)
    ap.add_argument("--produce-version-max", type=int, default=3)
    ap.add_argument("--dump", default=None, help="append raw request frames here")
    args = ap.parse_args()
    host, port = args.listen.rsplit(":", 1)
    Broker(host, int(port), args.topic, args.facts, args.received,
           args.produce_version_max, args.dump).serve()


if __name__ == "__main__":
    sys.exit(main())
