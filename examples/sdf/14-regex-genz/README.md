# 14 · regex — a match filter, with the boundary written down

**Ported from** `stateful-dataflow-examples`: `primitives/regex`（`filter` + regex crate；
该示例自述的主题其实是"**如何引入 crates.io 依赖**"，那部分我们不抄——AGENTS §1.1 不因移植引入第三方依赖）。

**What SDF does**: a `filter` SmartModule calling `Regex::is_match` with the pattern
`(199[7-9])|(200[0-9])|(201[0-2])`, keeping the Gen-Z birth years.

**What moonflux does here**: the pattern is a **spec-level filter** —
`{"type":"regex","pattern":"…"}` (optional `"invert": true`) — served by the kernel's own engine
([`core/regex`](../../../core/regex/)), which is pure computation, so it lives in `core` with
no IO, no clock and no third-party dependency. The program is compiled **at apply time**: an
unsupported construct is a publish-time rejection with a named reason, never a per-record
surprise.

```bash
EXE=_build/native/debug/build/apps/cli/cli.exe
$EXE pipeline run --data-dir "$(mktemp -d)" --spec examples/sdf/14-regex-genz/spec.json
$EXE pipeline run --data-dir "$(mktemp -d)" --spec examples/sdf/14-regex-genz/spec-invert.json
# and the negative example: this one must be REFUSED at apply
$EXE pipeline apply --data-dir "$(mktemp -d)" --file examples/sdf/14-regex-genz/spec-unsupported.json
```

**The engine's subset, stated rather than implied** (also in `core/regex`'s header):
literals, `.`, `*`, `+`, `?`, `{n}`, `{n,m}`, classes `[…]`/`[^…]` with ranges, `^`/`$`
(**string** anchors, no multiline flag), groups, alternation `|`, and the escapes
`\d \w \s \D \W \S` plus escaped metacharacters. All matching is **byte/ASCII** oriented,
like the records themselves.

**Refused by name** (this is the honest boundary): `\b`/`\B`, backreferences (`\1`),
lookaround (`(?=` `(?!` `(?<=` `(?<!`), named groups, inline flags (`(?i)`), lazy/possessive
quantifiers (`*?`), and Unicode classes (`\p{…}`). `spec-unsupported.json` is that boundary
turned into a fixture: `(?=1998)` is a lookahead, and the case expects `apply` to refuse it.

**Why Thompson, not backtracking**: the engine simulates a set of NFA states instead of
backtracking, so matching is linear in the input and cannot be made to blow up by a
pathological pattern — the same reasoning that keeps wall-clock out of the gates
(README 决策 33/59).
