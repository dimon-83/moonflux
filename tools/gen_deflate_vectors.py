#!/usr/bin/env python3
"""Generate core/codec_test/deflate_gen.mbt — DEFLATE golden vectors
anchored to Python's zlib (P25).

The anchor discipline (the same one that pinned CRC-32C and the Kafka
RecordBatch): when both sides of a wire are ours, a third-party
implementation must say what the bytes mean. Python's zlib compresses
every sample three ways — the zlib container, the gzip container, and
raw DEFLATE — plus the reference checksums (zlib.crc32 / zlib.adler32).
Our decoder must read all of it back byte-identical; our compressor's
output is re-inflated here by our own decoder and, in the e2e gate, by
the Python test broker.

Samples are deterministic and deliberately awkward: empty input, a
single byte, short text, a long single-symbol run (overlapping LZ77
copies at distance 1), a run longer than the 258-byte match cap,
pseudo-random bytes (incompressible — exercises the literal path), and
a mixed text payload large enough for real matching.

Usage:
  python3 tools/gen_deflate_vectors.py            # (re)generate
  python3 tools/gen_deflate_vectors.py --check    # fail if stale
"""

import gzip as gzip_mod
import pathlib
import sys
import zlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
GEN_MBT = ROOT / "core/codec_test/deflate_gen.mbt"

HEADER = """// SPDX-License-Identifier: Apache-2.0
// AUTO-GENERATED from tools/gen_deflate_vectors.py — do not edit.
// Regenerate: python3 tools/gen_deflate_vectors.py
// The Python zlib implementation is the source of truth: these are the
// bytes IT produces, and our decoder must read every one back
// byte-identical (the external anchor for a both-sides-are-ours codec).
"""


def deterministic_samples():
    """The corpus: deterministic, awkward, sizes from 0 to 64 KiB."""
    samples = []
    samples.append(("empty", b""))
    samples.append(("single-byte", b"A"))
    samples.append(("short-text", b"hello, deflate!"))
    # distance-1 replication: the classic overlapping LZ77 copy
    samples.append(("single-symbol-run", b"x" * 5000))
    # a run longer than the 258-byte match cap forces back-to-back
    # length codes for the same position
    samples.append(("long-run", b"\xab" * 700))
    # pseudo-random bytes: incompressible, exercises the literal path
    value = 0x12345678
    rnd = bytearray()
    for _ in range(4096):
        value = (value * 1103515245 + 12345) & 0x7FFFFFFF
        rnd.append(value & 0xFF)
    samples.append(("pseudo-random", bytes(rnd)))
    # mixed text large enough for real matching across lines
    lines = []
    for i in range(2000):
        lines.append(
            f"record-{i % 97}: the quick brown fox jumps over lazy dog {i * 7 % 101}"
        )
    samples.append(("mixed-text", "\n".join(lines).encode()))
    # 64 KiB of zeros: the worst-case ratio (bomb-shaped, but small)
    samples.append(("zeros-64k", b"\x00" * 65536))
    return samples


def build_cases():
    cases = []
    for name, data in deterministic_samples():
        compressor = zlib.compressobj(6, zlib.DEFLATED, -15)
        raw = compressor.compress(data) + compressor.flush()
        cases.append(
            {
                "name": name,
                "data_hex": data.hex(),
                "zlib_hex": zlib.compress(data, 6).hex(),
                "zlib9_hex": zlib.compress(data, 9).hex(),
                "gzip_hex": gzip_mod.compress(data).hex(),
                "raw_hex": raw.hex(),
                "crc32": zlib.crc32(data) & 0xFFFFFFFF,
                "adler32": zlib.adler32(data) & 0xFFFFFFFF,
            }
        )
    return cases


def render(cases):
    lines = [
        HEADER,
        "",
        "///|",
        "/// One DEFLATE golden-vector case.",
        "struct DeflateCase {",
        "  name : String",
        "  data_hex : String",
        "  zlib_hex : String",
        "  zlib9_hex : String",
        "  gzip_hex : String",
        "  raw_hex : String",
        "  crc32_hex : String",
        "  adler32_hex : String",
        "} derive(Debug, Eq)",
        "",
        "///|",
        "let deflate_cases : Array[DeflateCase] = [",
    ]
    for case in cases:
        lines.append("  DeflateCase::{")
        lines.append('    name: "%s",' % case["name"])
        lines.append('    data_hex: "%s",' % case["data_hex"])
        lines.append('    zlib_hex: "%s",' % case["zlib_hex"])
        lines.append('    zlib9_hex: "%s",' % case["zlib9_hex"])
        lines.append('    gzip_hex: "%s",' % case["gzip_hex"])
        lines.append('    raw_hex: "%s",' % case["raw_hex"])
        lines.append('    crc32_hex: "%08x",' % case["crc32"])
        lines.append('    adler32_hex: "%08x",' % case["adler32"])
        lines.append("  },")
    lines.append("]")
    return "\n".join(lines) + "\n"


def main():
    cases = build_cases()
    content = render(cases)
    if "--check" in sys.argv:
        if GEN_MBT.exists() and GEN_MBT.read_text() == content:
            print("deflate_gen.mbt is up to date")
            return
        print(
            f"{GEN_MBT} is stale — run: python3 tools/gen_deflate_vectors.py",
            file=sys.stderr,
        )
        sys.exit(1)
    GEN_MBT.write_text(content)
    print(f"wrote {GEN_MBT} ({len(cases)} cases)")


if __name__ == "__main__":
    main()
