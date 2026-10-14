#!/usr/bin/env python3
"""Static hygiene audit for the E2E gate scripts — it runs NO gate.

Why this exists: a gate suite that hangs, or that leaves a process holding the
caller's pipe, cannot be diagnosed by running it (that is the thing that fails,
and it takes the caller down with it). So the properties that matter are checked
by READING the scripts:

  * `read` without an input redirection reads the inherited stdin. A gate run
    from a terminal then blocks forever on the human's keyboard — the suite never
    finishes and the caller waits with it. Every `read` must name where its line
    comes from (`< file`, a pipe, or `-u fd`).
  * a background process (`&`) that is never killed or waited on survives the
    gate. Before this repo detached the suite, such a survivor inherited the
    caller's stdout/stderr and kept the pipe open, which is how "the suite hung"
    and "the client died" turned out to be the same event.
  * a `trap ... EXIT` cleanup is what makes the previous point true on the
    failure paths too, not just the happy one.
  * `wait` with no timeout and `while true` are unbounded: a gate that uses them
    can hang, and a hang is the failure this file exists to prevent.
  * a `pkill`/`killall` pattern that is not scoped to a temp path can kill
    something it did not start (including the tool that invoked the suite).
  * the SUITE's own mechanisms (`--suite`): a per-step process group and a
    watchdog in gates.sh, detached stdin, and the helper scripts that make rule 1
    real. Deleting one of these silently returns the repository to the state
    where a gate run could take its caller down, so their presence is checked
    the same way a gate's hygiene is.

Usage:
  python3 scripts/audit-gate-hygiene.py [dir-or-file...]     # default: scripts/
Exit code is 0 when clean, 1 when any risk is reported.
"""
from __future__ import annotations

import pathlib
import re
import sys

# `read` as a COMMAND, not the word. Matching the bare substring flagged
# read-only, rfile.read(), sys.stdin.read() and prose in messages — 89 "risks" in
# 59 gates, which is the kind of guard that gets deleted along with its reason.
# A command-position `read` is preceded by start/;/&/|/while/do/then (optionally
# through VAR=value assignments) and is not followed by a word char or `-`.
READ_RE = re.compile(
    r"(?:^|[;&|]|\bwhile\b|\buuntil\b|\bdo\b|\bthen\b)"
    r"(?:\s+[A-Za-z_][A-Za-z0-9_]*=\S*)*"
    r"\s+read\b(?![-\.\w])"
)
# fed by a pipe, a file, a here-string, a dup'd fd, or a `done < file`
REDIRECTED = re.compile(r"\||<\s*[\"$'\w]|-u\s+\d|done\s*<")
BACKGROUND = re.compile(r"&\s*(#.*)?$")
TRAP_EXIT = re.compile(r"trap\s+\S+\s+EXIT|trap\s+'[^']*'\s+EXIT")
KILLED = re.compile(r"kill\b|pkill\b|wait\b")
WAIT_BARE = re.compile(r"^\s*wait\s*$")
WHILE_TRUE = re.compile(r"^\s*while\s+(true|:)\b")
BROAD_KILL = re.compile(r"\b(pkill|killall)\b[^\n]*")
# a kill pattern is scoped when it names this gate's own temp path: a
# moonflux-<gate> name, /tmp, a *_DIR/*_WORK style variable, or an e2e- script
SCOPED = re.compile(r"(moonflux-|/tmp/|\$[A-Za-z_]+|e2e-)")


def audit(path: pathlib.Path) -> list[str]:
    problems: list[str] = []
    text = path.read_text(encoding="utf-8", errors="replace")
    lines = text.splitlines()
    for number, line in enumerate(lines, 1):
        stripped = line.split("#", 1)[0]
        # 1. read without a source
        if READ_RE.search(stripped) and not REDIRECTED.search(stripped):
            # a `read` in a `while ... read` that is later redirected via `done <`
            # is fine; find out whether some `done` line in the file redirects
            if not any(re.search(r"done\s*<", ln) for ln in lines):
                problems.append(
                    f"{path}:{number}: `read` with no input redirection — it reads "
                    f"the inherited stdin and blocks when a human runs the suite: "
                    f"{line.strip()[:70]}"
                )
        # 2. unbounded wait / loop
        if WAIT_BARE.search(stripped):
            problems.append(
                f"{path}:{number}: bare `wait` (waits for EVERY child, with no "
                f"timeout) — use `wait $pid` on a pid you started, or don't wait"
            )
        if WHILE_TRUE.search(stripped):
            problems.append(
                f"{path}:{number}: `while true` — an unbounded loop in a gate can "
                f"hang the suite; bound it by count or a deadline"
            )
        # 3. a kill pattern that is not scoped to this gate's own temp path
        for match in BROAD_KILL.finditer(stripped):
            command = stripped[match.start():]
            if not SCOPED.search(command):
                problems.append(
                    f"{path}:{number}: unscoped `{match.group(1)}` — it can kill "
                    f"processes this gate did not start: {line.strip()[:70]}"
                )
    # 4. background processes need a cleanup trap (and some kill/wait)
    if any(BACKGROUND.search(ln.split("#", 1)[0]) for ln in lines):
        if not TRAP_EXIT.search(text):
            problems.append(
                f"{path}: starts background processes but has no `trap ... EXIT` "
                f"cleanup — a failure path leaves them running"
            )
        if not KILLED.search(text):
            problems.append(
                f"{path}: starts background processes but never kills or waits on "
                f"them — they survive the gate"
            )
    return problems


def audit_suite(root: pathlib.Path) -> list[str]:
    """The suite's own safety mechanisms must exist and stay wired."""
    problems: list[str] = []
    gates = root / "scripts" / "gates.sh"
    if not gates.is_file():
        return [f"{gates} is missing: the suite has no entry point"]
    text = gates.read_text(encoding="utf-8", errors="replace")
    # each step in its own process group, under a watchdog, with stdin detached:
    # this is what makes a hung gate reapable and stops a leaked child holding
    # the caller's pipe (the measured crash of a run that outlived its tool call)
    if "set -m" not in text:
        problems.append(
            f"{gates}: no `set -m` — steps no longer run in their own process "
            f"group, so a hung step can only be killed by its own pid"
        )
    if "MOONFLUX_GATES_STEP_TIMEOUT" not in text:
        problems.append(f"{gates}: no per-step watchdog — a hung gate stalls the suite")
    if "</dev/null" not in text:
        problems.append(
            f"{gates}: steps no longer detach stdin — a gate that reads it blocks"
        )
    ci = root / ".github" / "workflows" / "ci.yml"
    ci_text = ci.read_text(encoding="utf-8", errors="replace") if ci.is_file() else ""
    for needed in [
        "scripts/gates-bg.sh",
        "scripts/resource-watch.sh",
        "scripts/run-watched.sh",
        "scripts/audit-gate-hygiene.py",
        "AGENT.md",
    ]:
        if not (root / needed).exists():
            problems.append(f"{needed} is missing (AGENT.md rule 1's enforcement)")
    if ci_text and "run-watched.sh" not in ci_text:
        problems.append(
            f"{ci}: the docker cluster run is not watched — a long run's resource "
            f"evidence should be on disk next to its log"
        )
    return problems


def main(argv: list[str]) -> int:
    suite_only = "--suite" in argv
    argv = [a for a in argv if a != "--suite"]
    if suite_only:
        root = pathlib.Path(argv[1]) if len(argv) > 1 else pathlib.Path(".")
        problems = audit_suite(root)
        for problem in problems:
            print(problem)
        if problems:
            print(f"\naudit-gate-hygiene --suite: {len(problems)} problem(s)")
            return 1
        print("audit-gate-hygiene --suite: the suite's safety mechanisms are in place "
              "(per-step process group, watchdog, detached stdin, gates-bg/"
              "resource-watch/run-watched, AGENT.md)")
        return 0
    roots = [pathlib.Path(a) for a in argv[1:]] or [pathlib.Path("scripts")]
    files: list[pathlib.Path] = []
    for root in roots:
        if root.is_dir():
            files.extend(sorted(root.glob("e2e-*.sh")))
        else:
            files.append(root)
    problems: list[str] = []
    for path in files:
        problems.extend(audit(path))
    for problem in problems:
        print(problem)
    if problems:
        print(f"\naudit-gate-hygiene: {len(problems)} risk(s) in {len(files)} gate(s)")
        return 1
    print(f"audit-gate-hygiene: {len(files)} gate(s) clean "
          f"(no stdin reads, no unbounded waits/loops, no unscoped kills, "
          f"background processes have cleanup)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
