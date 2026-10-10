# 05 · split — one source, two filtered streams

**Ported from** `primitives/split/filter` (one `user` topic → `child` + `adult`).

**What SDF does**: one service with **two sinks, each carrying its own
`transforms:`** — the split is topological (sink-scoped transforms), not an
operator.

**What moonflux does here**: a spec has exactly one sink and one topic, so the
split is **two ingress specs** over the same source file, each with its own
filter and its own topic. Both branches are asserted to partition the input:
two ERROR lines, one WARN line, no overlap.

```bash
EXE=_build/native/debug/build/apps/cli/cli.exe
$EXE pipeline run --data-dir "$(mktemp -d)" --spec examples/sdf/05-split-two-streams/spec-errors.json
$EXE pipeline run --data-dir "$(mktemp -d)" --spec examples/sdf/05-split-two-streams/spec-warns.json
```

**Difference worth knowing**: this is a genuine topological gap. SDF's service
fans out to N sinks inside one program; moonflux's applied topology is
**one program per node** (and one sink per spec). Two branches therefore mean
two pipelines — or two consumers applying different rules on the way out, which
is the same idea at a different layer.
