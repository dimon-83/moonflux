#!/usr/bin/env python3
"""Write a wire-protocol batch frame for the WebSocket gate.

The frame comes from the project's own golden vectors
(core/protocol/testdata/protocol_vectors.json) - the same bytes the
kernel's codec tests are checked against - with one edit: the base
offset is set to -1 (unassigned), which is what a producer sends. That
edit is legitimate by design: base_offset sits outside the CRC
precisely so a broker (or a producer) can rewrite it without
recomputing anything, which is what lets the vector be reused verbatim.

Usage:
  python3 tools/gen_ws_batch.py <out-path> [vector-name]
"""

import json
import pathlib
import struct
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
VECTORS = ROOT / "core/protocol/testdata/protocol_vectors.json"

DEFAULT_VECTOR = "multi-record"


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    out = sys.argv[1]
    name = sys.argv[2] if len(sys.argv) > 2 else DEFAULT_VECTOR
    cases = json.loads(VECTORS.read_text())
    case = next((c for c in cases if c["name"] == name), None)
    if case is None:
        print("no vector named %r in %s" % (name, VECTORS), file=sys.stderr)
        return 1
    frame = bytearray(bytes.fromhex(case["hex"]))
    # magic(3) + version(1) + length(4) = 8, so the base offset is 8..16
    frame[8:16] = struct.pack(">q", -1)
    pathlib.Path(out).write_bytes(bytes(frame))
    print("wrote %s (%d bytes, %d records, from vector %s)"
          % (out, len(frame), len(case["records"]), name))
    return 0


if __name__ == "__main__":
    sys.exit(main())
