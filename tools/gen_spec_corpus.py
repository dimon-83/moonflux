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

ROOT = pathlib.Path(__file__).resolve().parent.parent
CORPUS_JSON = ROOT / "core/spec/testdata/spec_corpus.json"
GEN_MBT = ROOT / "core/spec_test/corpus_gen.mbt"

HEADER = """\
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


def mbt_str(s: str) -> str:
    out = s.replace("\\", "\\\\").replace('"', '\\"')
    return '"%s"' % out


def render(doc: dict) -> str:
    out = [HEADER]
    for c in doc["valid"]:
        out.append(
            "  ValidCase::{ name: %s, json: %s },\n"
            % (json.dumps(c["name"]), mbt_str(c["json"]))
        )
    out.append(MIDDLE)
    for c in doc["invalid"]:
        codes = ", ".join(json.dumps(x) for x in c["expect_codes"])
        out.append(
            "  InvalidCase::{ name: %s, json: %s, expect_codes: [%s] },\n"
            % (json.dumps(c["name"]), mbt_str(c["json"]), codes)
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
