#!/usr/bin/env python3
"""Checks that consumer-group members' reported shares partition a topic.

Used by scripts/e2e-p9-groups.sh. Input: a file of lines of the form
`member <id> holds <topic>[<n>],<topic>[<m>]` (or `(nothing)`), the
partition count, the topic name, and the expected number of members.
Exits non-zero with a message on any violation — a partition held twice,
a partition nobody holds, an unexpected member count.
"""
import re
import sys


def main() -> int:
    path, partitions, topic = sys.argv[1], int(sys.argv[2]), sys.argv[3]
    expected_members = int(sys.argv[4]) if len(sys.argv) > 4 else None
    latest: dict[str, set[str]] = {}
    for line in open(path):
        line = line.strip()
        if not line:
            continue
        m = re.match(r"member (\S+) holds (.*)$", line)
        if not m:
            print(f"unparseable share line: {line}", file=sys.stderr)
            return 1
        held = set() if m.group(2) == "(nothing)" else set(m.group(2).split(","))
        latest[m.group(1)] = held
    if not latest:
        print("no member reported a share", file=sys.stderr)
        return 1
    if expected_members is not None and len(latest) != expected_members:
        print(f"expected {expected_members} member(s), saw {sorted(latest)}", file=sys.stderr)
        return 1
    owned = [p for share in latest.values() for p in share]
    if len(owned) != len(set(owned)):
        print(f"a partition is held twice: {sorted(owned)}", file=sys.stderr)
        return 1
    expected = {f"{topic}[{i}]" for i in range(partitions)}
    if set(owned) != expected:
        print(f"held {sorted(set(owned))}, expected {sorted(expected)}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
