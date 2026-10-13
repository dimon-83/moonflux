#!/usr/bin/env python3
"""Flag `$VAR` written immediately before a non-ASCII character in shell scripts.

Why this is a gate rather than a style rule: bash keeps consuming bytes for the
variable name, so `$OUT（…` is not "$OUT followed by a full-width parenthesis" —
it is a variable literally named `OUT（`, and the script dies at RUNTIME with
"OUT（: unbound variable" only on the branch that reaches it. Measured twice in
this repository (a gate's pass message and a deployment script's final echo): both
times the surrounding lines looked right, and both times the failure appeared only
when that line ran.

The fix is always `"${OUT}（…"`. Braces end the name unambiguously.
"""
from __future__ import annotations

import pathlib
import re
import sys

PATTERN = re.compile(r"\$([A-Za-z_][A-Za-z0-9_]*|\{[A-Za-z_][A-Za-z0-9_]*\})([^\x00-\x7f])")


def main(argv: list[str]) -> int:
    roots = [pathlib.Path(a) for a in argv[1:]] or [pathlib.Path("scripts")]
    files: list[pathlib.Path] = []
    for root in roots:
        files.extend(sorted(root.glob("*.sh")) if root.is_dir() else [root])
    problems = []
    for path in files:
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            if line.lstrip().startswith("#"):
                continue
            for match in PATTERN.finditer(line):
                if match.group(1).startswith("{"):
                    continue
                problems.append((path, number, match.group(0), line.strip()))
    for path, number, found, line in problems:
        print(f"{path}:{number}: '{found}' — a variable name abutting a non-ASCII "
              f"character; write ${{…}} instead | {line[:70]}")
    if problems:
        print(f"audit-shell-vars: {len(problems)} problem(s)")
        return 1
    print(f"audit-shell-vars: {len(files)} script(s) clean")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
