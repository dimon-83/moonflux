#!/usr/bin/env python3
# Every command name in `is_command` must have a dispatch arm, and vice versa.
#
# Why this is a gate: `main` finds the subcommand by asking `is_command`, then
# dispatches with a `match cmd`. Two lists, one fact. Adding `"run" => cmd_run`
# without adding `text == "run"` makes the CLI print usage for a verb it is
# about to support — which is exactly what happened while wiring `run list`
# (P37-2), and the message pointed at the command that WAS there.
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
MAIN = ROOT / "apps" / "cli" / "main.mbt"


def main() -> int:
    src = MAIN.read_text(encoding="utf-8")
    block = src.split("fn is_command", 1)
    if len(block) != 2:
        print("audit-verbs: could not find is_command in apps/cli/main.mbt")
        return 1
    body = block[1].split("\n  }", 1)[0]
    named = set(re.findall(r'text == "([a-z-]+)"', body))

    # the dispatch arms: `"x" => cmd_x(rest)` inside `main`
    dispatch_block = src.split("let rest = args[start + 1:args.length()].to_owned()", 1)
    if len(dispatch_block) != 2:
        print("audit-verbs: could not find the dispatch block")
        return 1
    arms = set(
        re.findall(r'"([a-z-]+)" => cmd_[a-z_]+\(rest\)', dispatch_block[1])
    )

    missing_arm = sorted(named - arms)
    missing_name = sorted(arms - named)
    failed = False
    if missing_arm:
        print("audit-verbs: named as a command but has no dispatch arm:")
        for name in missing_arm:
            print(f"  {name}")
        failed = True
    if missing_name:
        print("audit-verbs: has a dispatch arm but is not a command name (the")
        print("CLI would print usage for it before ever reaching the arm):")
        for name in missing_name:
            print(f"  {name}")
        failed = True
    if failed:
        return 1
    print(
        f"audit-verbs: {len(named)} command(s) named and dispatched "
        f"({', '.join(sorted(named))})"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
