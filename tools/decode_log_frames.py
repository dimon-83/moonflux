#!/usr/bin/env python3
"""Decode a segment file (concatenated wire-protocol batch frames) and
print one line per record: `<offset>\t<key>\t<value>`.

Used by the P4 editor gate to assert what the *browser* wrote without
opening a connection to the broker — the segment file is the protocol
stream, so it can be read directly. Base offsets are not in the file
per-record, so the offset printed is the record's position in the log.

Usage: python3 tools/decode_log_frames.py <segment-file>
"""

import struct
import sys


def uleb(buf: bytes, i: int):
    shift = 0
    value = 0
    while True:
        b = buf[i]
        i += 1
        value |= (b & 0x7F) << shift
        if not b & 0x80:
            return value, i
        shift += 7
        if shift > 63:
            raise ValueError("varint too long")


def main() -> int:
    data = open(sys.argv[1], "rb").read()
    i = 0
    offset = 0
    while i < len(data):
        if data[i:i + 3] != b"MFB":
            print(f"bad magic at byte {i}", file=sys.stderr)
            return 1
        length = struct.unpack(">I", data[i + 4:i + 8])[0]
        body = data[i + 8:i + 8 + length]
        base = struct.unpack(">q", body[0:8])[0]
        count = struct.unpack(">I", body[12:16])[0]
        blob_len = struct.unpack(">I", body[16:20])[0]
        blob = body[20:20 + blob_len]
        j = 0
        for _ in range(count):
            total, j = uleb(blob, j)
            end = j + total
            ts = struct.unpack(">q", blob[j:j + 8])[0]
            j += 8
            klen, j = uleb(blob, j)
            key = blob[j:j + klen]
            j += klen
            vlen, j = uleb(blob, j)
            value = blob[j:j + vlen]
            j += vlen
            hcount, j = uleb(blob, j)
            for _h in range(hcount):
                hklen, j = uleb(blob, j)
                j += hklen
                hvlen, j = uleb(blob, j)
                j += hvlen
            assert j == end, "record length mismatch"
            print(f"{offset}\t{base}\t{key.decode(errors='replace')}\t{value.decode(errors='replace')}")
            offset += 1
        i += 8 + length
    return 0


if __name__ == "__main__":
    sys.exit(main())
