# 06 · merge — two sources, one topic

**Ported from** `primitives/merge` (trucks + sedans → licenses).

**What SDF does**: one service with two `sources:`, each carrying its own
`transforms:` (source-scoped maps), fanning into one sink.

**What moonflux does here**: merge happens at the **topic**. Two ingress
pipelines name the same topic (`sdf-06-licenses`), so the log *is* the merged
stream, in append order — and the case asserts offsets 0..3 across both inputs.

```bash
EXE=_build/native/debug/build/apps/cli/cli.exe
D=$(mktemp -d)
$EXE pipeline run --data-dir "$D" --spec examples/sdf/06-merge-two-sources/spec-a.json
$EXE pipeline run --data-dir "$D" --spec examples/sdf/06-merge-two-sources/spec-b.json
$EXE consume --topic sdf-06-licenses --from 0 --data-dir "$D" | cut -f1,4   # == expected-merged.txt
```

**Difference worth knowing**: SDF normalizes both shapes inside the service
(per-source maps). moonflux has no in-stream join or per-source map here: the
topic takes what each producer writes, and normalizing would be a transform on
each ingress pipeline (or on the way out). Merging is a place, not an operator.
