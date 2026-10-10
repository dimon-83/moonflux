# 03 · filter-map — drop short, uppercase long

**Ported from** `primitives/filter-map`: `if input.len() > 10 { Some(upper) } else { None }`.

**What SDF does**: one Rust `filter-map` SmartModule does both the decision and
the transformation.

**What moonflux does here**: two chained nodes — the wasm filter
(`{"min_len": 11}`) decides, then an **mbel rule** (`upper(value)`) transforms.
A chain mixes engines freely; each node's contract is respected (the operator
sees the whole batch, the rule sees one record).

```bash
EXE=_build/native/debug/build/apps/cli/cli.exe
$EXE pipeline run --data-dir "$(mktemp -d)" --spec examples/sdf/03-filter-map-uppercase/spec.json
```

**Note**: `len > 10` in Rust is a byte length; the operator compares byte
lengths too, so the boundary behaviour matches for ASCII input. The
`min_len` semantics are documented in `apps/operator-filter/operator.mbt`.
