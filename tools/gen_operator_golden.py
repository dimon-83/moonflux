#!/usr/bin/env python3
"""Generate scripts/testdata/operator-golden.txt — the shared input for
the native-vs-wasm operator crosscheck (P2 gate).

The file is the source of truth: both legs (mbel `upper(value)` and the
wasm uppercase operator) consume the SAME lines, so any divergence in
the outputs is a semantic difference, not a data difference. Lines are
newline-terminated because the file source splits on newlines.

The corpus is deliberately awkward-but-ASCII: mixed case, digits,
punctuation that must survive untransformed, an empty line, and a long
line (multi-byte record, still one record).

Usage:
  python3 tools/gen_operator_golden.py            # (re)generate
  python3 tools/gen_operator_golden.py --check    # fail if stale
"""

import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
GOLDEN = ROOT / "scripts/testdata/operator-golden.txt"

# One record per line; ASCII only (the mbel upper() scope is ASCII).
LINES = [
    "hello",
    "mixed Case Line",
    "already UPPER",
    "digits 0123456789 and symbols !@#$%^&*()_+-=[]{};':\",.<>/?|`~",
    "caf\u00e9 latte",  # non-ASCII: must pass through byte-identical
    "",
    "trailing spaces   ",
    "a" * 300,
    "tab\tinside",
    "the quick brown fox jumps over the lazy dog",
]


def render() -> str:
    return "".join(line + "\n" for line in LINES)


def main() -> int:
    want = render()
    if "--check" in sys.argv:
        have = GOLDEN.read_text() if GOLDEN.exists() else None
        if have != want:
            print(f"{GOLDEN} is stale; regenerate with "
                  f"python3 tools/gen_operator_golden.py", file=sys.stderr)
            return 1
        print("operator golden data is up to date")
        return 0
    GOLDEN.parent.mkdir(parents=True, exist_ok=True)
    GOLDEN.write_text(want)
    print(f"wrote {GOLDEN} ({len(LINES)} records)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
