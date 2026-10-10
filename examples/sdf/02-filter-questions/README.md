# 02 · filter — keep the question

**Ported from** `primitives/filter`: keep sentences containing `?`.

**What SDF does**: a Rust `filter` SmartModule returning `bool` — `true` passes
the record, `false` drops it (1 → 0 or 1).

**What moonflux does here**: the same decision as a **sandboxed wasm operator**
(`apps/operator-filter`, ABI v1) configured through `mf_op_init`
(`{"contains": "?"}`). It cannot be an mbel rule: an expression transform must
return a string, so "drop this record" has no spelling there — the operator's
batch contract (`Array[Record] -> Array[Record]`) is what makes dropping a
shorter batch.

```bash
EXE=_build/native/debug/build/apps/cli/cli.exe
$EXE pipeline run --data-dir "$(mktemp -d)" --spec examples/sdf/02-filter-questions/spec.json
```

**Requires** `scripts/build-operators.sh` to have built
`_build/wasm/debug/build/apps/operator-filter/operator-filter.wasm`.
