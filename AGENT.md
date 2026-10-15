# AGENT.md — the two iron rules

This file is deliberately short and in English: it is what an agent must read even
when it reads nothing else. The project charter is [AGENTS.md](AGENTS.md) (Chinese,
and long); this file carries only rules whose violation has already cost this
repository real time.

---

## Rule 1 (IRON): control and release resources — in the gates AND inside moonflux

Every process, file descriptor, pipe, socket, child process, log line, and heap
allocation must be **bounded** and **released**. This is not a performance goal;
it is a correctness and availability requirement, and it applies with equal force
to the gate scripts and to the platform itself.

What that means concretely, with the failure each item has already caused here:

1. **Never read from inherited stdin.** A `read` without a redirection blocks
   forever when a human runs the suite from a terminal, and the suite then never
   finishes. Name the source (`< file`, a pipe, `-u fd`).
2. **No unbounded wait.** `wait` with no pid, or `while true`, can hang the suite.
   Wait on a pid you started, bound every loop by count or deadline.
3. **Never leave a child behind.** Every background process must be reaped on
   every exit path, including failure — a `trap ... EXIT` that kills what the
   script started, scoped to the script's own temp path (an unscoped `pkill` can
   kill something it did not start, including the tool that invoked the suite).
   A survivor that inherited the caller's stdout keeps that pipe open, so the
   caller waits on a pipe held by a daemon it never started. That is exactly how
   "a gate hung" and "the client died" turned out to be one event.
4. **Bound every output.** Text written to a file is free; text drawn into a
   terminal, a CI log view, or an agent's transcript is re-rendered on every run
   and its memory is not given back. Full output goes to a log file; the console
   gets a summary and, on failure, a bounded tail.
5. **Reuse, do not accumulate.** A slot that was released must be reused rather
   than appended to. Measured leak: a supervised task that starts and stops
   repeatedly grew its supervisor's bookkeeping by one corpse per cycle — memory
   never released and every pass paying for the corpses.
6. **Close what you open, and say so when you cannot.** Handles, sockets and
   clients are released on every path; a failure to release is reported, never
   swallowed. A redirect into a missing directory fails silently, which is worse
   than failing.
7. **Run heavy work detached — and never in the same command that waits for it.**
   One long foreground command is what exposes the caller to every pipe the work
   spawns. Heavy work is launched detached and its log is polled in SHORT
   commands. Measured twice, in two shapes: a launch that then sleeps in the same
   command is reaped with its process group when the call ends, and a detached
   launch can still be interrupted *inside its own cleanup*, leaving a child
   alive. So: poll in a separate short command, verify the release afterwards,
   and clean up explicitly when verification fails.
8. **Prefer bounded to patient.** A timeout is a budget: a step that hangs must
   be reaped whole (its own process group), recorded as failed, and explained.

**Enforced by, not by good intentions:**
`scripts/gates-bg.sh` (fully detached launch, returns immediately),
`scripts/resource-watch.sh` (out-of-process sampling: free memory, swap, process
count, and the CLIENTS' resident size as well as the workload's),
`scripts/audit-gate-hygiene.py` (static: unredirectioned `read`, unbounded waits,
background processes without a cleanup trap, unscoped kills) and the per-step
process group plus watchdog in `scripts/gates.sh`. The hygiene audit runs in the
suite's static section, and both CI and the full run must stay green.

## Rule 2: documentation languages

- **This file and any other agent-facing rule file are ENGLISH.** An agent's
  environment, tooling and error text are English; rules written for agents are
  written in English.
- **Everything else stays Chinese** — decisions, feature matrix, roadmap,
  progress board, tickets, design notes, guides. Chinese is the language the
  humans on this project read.
- **Bilingual duplicates are the target, not the current state.** Where a Chinese
  document carries a rule an English reader needs, an English twin is produced
  later. Until then the rule lives in this file, and the Chinese document carries
  a pointer to it. Do not generate the twins speculatively; generate them when a
  reader needs them, and keep them next to the original.

---

## How to run the verification suite (the short version)

```sh
scripts/gates-bg.sh              # full suite, detached; prints the log path
scripts/gates-bg.sh fast         # static + builds + tests, no E2E gates
tail -3 "$(cat /tmp/moonflux-gates.last)"     # poll in a SHORT command
```

Never run the suite as one long foreground command. When a run needs evidence
about resources rather than about behaviour, start `scripts/resource-watch.sh`
first, then read its samples: a run that crashes its own caller cannot be
diagnosed from the run's own output, because that output dies with the caller.
