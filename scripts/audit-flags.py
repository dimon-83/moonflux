#!/usr/bin/env python3
# Every flag used as a BOOLEAN must be registered as a boolean.
#
# Why this is a gate and not a style note: `parse_flags` decides whether a
# `--flag` consumes the next argument by asking `flag_is_boolean`. A flag used
# as a boolean but missing from that list therefore SWALLOWS the following
# argument. That has now happened twice in this repository:
#
#   * P18: a boolean flag ate the flag after it (fixed, and the list exists
#     because of it);
#   * P37: `--set` (new) ate `-f <file>`, and `pipeline apply --set -f x.json`
#     failed with "missing required flag --file" — the error pointed at the
#     flag that was present, which is the worst kind of misleading.
#
# The rule: a flag is BOOLEAN if it is used as `flags.get("name") is Some(_)`
# and its value is never read (no `is Some(binding)`, no bare
# `flags.get("name")` used as a value). A flag whose value is read somewhere is
# VALUED, even when one call site only asks whether it was given — `--remote`
# is exactly that case, and demanding it in the boolean list would be wrong.
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CLI = ROOT / "apps" / "cli"
boolean_use = re.compile(r'flags\.get\("([a-z0-9-]+)"\)\s+is\s+Some\(_\)')
value_use = re.compile(r'flags\.get\("([a-z0-9-]+)"\)\s+is\s+Some\((?!_\))')
bare_use = re.compile(r'flags\.(?:get|require)\("([a-z0-9-]+)"\)(?!\s+is\s+Some)')


def main() -> int:
    src = "\n".join(p.read_text(encoding="utf-8") for p in sorted(CLI.glob("*.mbt")))
    booleans = set(boolean_use.findall(src))
    valued = set(value_use.findall(src)) | set(bare_use.findall(src))
    main_mbt = (CLI / "main.mbt").read_text(encoding="utf-8")
    block = main_mbt.split("fn flag_is_boolean", 1)
    if len(block) != 2:
        print("audit-flags: could not find flag_is_boolean in apps/cli/main.mbt")
        return 1
    body = block[1].split("\n}", 1)[0]
    registered = set(re.findall(r'name == "([a-z0-9-]+)"', body))

    missing = sorted(booleans - valued - registered)
    if missing:
        print(
            "audit-flags: these flags are used as booleans but are not in "
            "flag_is_boolean, so each one swallows the next argument:"
        )
        for name in missing:
            print(f"  --{name}")
        print(
            "add them to flag_is_boolean in apps/cli/main.mbt (or read their "
            "value, if they are not booleans at all)"
        )
        return 1

    # stale entries are harmless but they are also how the list drifts: report
    # only when a registered flag is used as a VALUE somewhere, which would
    # make the registration a lie
    lying = sorted(registered & valued)
    if lying:
        print(
            "audit-flags: registered as boolean but their value is read "
            "elsewhere, so the registration is wrong:"
        )
        for name in lying:
            print(f"  --{name}")
        return 1

    print(
        f"audit-flags: {len(booleans)} boolean flag(s) checked "
        f"({', '.join('--' + n for n in sorted(booleans))}); "
        f"{len(registered)} registered"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
