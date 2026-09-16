#!/usr/bin/env python3
"""Generate core/protocol_test/vectors_gen.mbt from
core/protocol/testdata/protocol_vectors.json.

The JSON document is the source of truth for golden-vector
crosschecks (AGENTS §5: vectors live in data files); this script
renders it into a MoonBit module the test package can compile.

Usage:
  python3 tools/gen_protocol_vectors.py            # (re)generate
  python3 tools/gen_protocol_vectors.py --check    # fail if stale
"""

import json
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from moonbit_fmt import mbt_str, struct_literal  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parent.parent
VECTORS_JSON = ROOT / "core/protocol/testdata/protocol_vectors.json"
GEN_MBT = ROOT / "core/protocol_test/vectors_gen.mbt"

HEADER = """\
// SPDX-License-Identifier: Apache-2.0
// AUTO-GENERATED from core/protocol/testdata/protocol_vectors.json — do not edit.
// Regenerate: python3 tools/gen_protocol_vectors.py
// The JSON document is the source of truth; this module only renders it.

///|
/// One golden-vector case: a records spec (JSON) plus the exact bytes
/// the v1 encoder must produce for it.
struct VectorCase {
  name : String
  base_offset : Int64
  hex : String
  records_json : String
} derive(Debug, Eq)

///|
let vector_cases : Array[VectorCase] = [
"""


def render(cases: list) -> str:
    # Emitted in the shape moon fmt settles on: the hex and JSON payloads
    # are long enough that every case expands to one field per line, and
    # `moon fmt` must be a no-op for `--check` to mean anything.
    out = [HEADER]
    for c in cases:
        out.append(
            struct_literal(
                "VectorCase",
                [
                    ("name", json.dumps(c["name"])),
                    ("base_offset", "%dL" % int(c["base_offset"])),
                    ("hex", '"%s"' % c["hex"]),
                    (
                        "records_json",
                        mbt_str(
                            json.dumps(c["records"], separators=(",", ":"))
                        ),
                    ),
                ],
                2,
            )
        )
    out.append("]\n")
    return "".join(out)


def main() -> int:
    cases = json.loads(VECTORS_JSON.read_text())
    text = render(cases)
    if "--check" in sys.argv:
        if not GEN_MBT.exists():
            print(f"missing {GEN_MBT}", file=sys.stderr)
            return 1
        if GEN_MBT.read_text() != text:
            print(
                f"{GEN_MBT} is stale; regenerate with "
                "python3 tools/gen_protocol_vectors.py",
                file=sys.stderr,
            )
            return 1
        print("vectors_gen.mbt is up to date")
        return 0
    GEN_MBT.write_text(text)
    print(f"wrote {GEN_MBT} ({len(cases)} cases)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
