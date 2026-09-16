#!/usr/bin/env python3
"""Generate core/spec_test/corpus_gen.mbt from
core/spec/testdata/spec_corpus.json (source of truth, AGENTS §5).

Usage:
  python3 tools/gen_spec_corpus.py            # (re)generate
  python3 tools/gen_spec_corpus.py --check    # fail if stale
"""

import json
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from moonbit_fmt import mbt_str, struct_literal  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parent.parent
CORPUS_JSON = ROOT / "core/spec/testdata/spec_corpus.json"
GEN_MBT = ROOT / "core/spec_test/corpus_gen.mbt"

HEADER = """\
// SPDX-License-Identifier: Apache-2.0
// AUTO-GENERATED from core/spec/testdata/spec_corpus.json — do not edit.
// Regenerate: python3 tools/gen_spec_corpus.py

///|
/// A valid spec document (must parse).
struct ValidCase {
  name : String
  json : String
} derive(Debug, Eq)

///|
/// An invalid spec document: must fail and report every listed code.
struct InvalidCase {
  name : String
  json : String
  expect_codes : Array[String]
} derive(Debug, Eq)

///|
let valid_cases : Array[ValidCase] = [
"""

MIDDLE = """\
]

///|
let invalid_cases : Array[InvalidCase] = [
"""


def render(doc: dict) -> str:
    # Every literal is emitted in the shape moon fmt settles on, so
    # `moon fmt` is a no-op on this file and `--check` stays meaningful.
    out = [HEADER]
    for c in doc["valid"]:
        out.append(
            struct_literal(
                "ValidCase",
                [("name", json.dumps(c["name"])), ("json", mbt_str(c["json"]))],
                2,
            )
        )
    out.append(MIDDLE)
    for c in doc["invalid"]:
        out.append(
            struct_literal(
                "InvalidCase",
                [
                    ("name", json.dumps(c["name"])),
                    ("json", mbt_str(c["json"])),
                    ("expect_codes", [json.dumps(x) for x in c["expect_codes"]]),
                ],
                2,
            )
        )
    out.append("]\n")
    return "".join(out)


def main() -> int:
    doc = json.loads(CORPUS_JSON.read_text())
    text = render(doc)
    if "--check" in sys.argv:
        if not GEN_MBT.exists() or GEN_MBT.read_text() != text:
            print(
                f"{GEN_MBT} is stale; regenerate with python3 tools/gen_spec_corpus.py",
                file=sys.stderr,
            )
            return 1
        print("corpus_gen.mbt is up to date")
        return 0
    GEN_MBT.write_text(text)
    print(
        f"wrote {GEN_MBT} ({len(doc['valid'])} valid, {len(doc['invalid'])} invalid)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
