# 01 · map — mask the digits of an SSN

**Ported from** `stateful-dataflow-examples`:
`primitives/map`（mask `ssn`）、`dataflows/mask-user-pii`（raw 文本掩码）、
`packages/mask-ssn`（可复用函数资产）。

**What SDF does**: a `map` SmartModule written in Rust with the `regex` crate
replaces every digit with `*`; the package variant reuses the same function
through `imports: pkg: example/mask-ssn@0.1.0`.

**What moonflux does here**: the same masking as an **mbel function-set asset**
(`fns.json`, set `pii`, function `mask_ssn`) referenced by name from the spec —
the platform's counterpart of an SDF package. The asset goes straight into the
same data dir the run reads: `function-set create` takes `--data-dir` (P30/T107),
so no server is needed to install it. (Before that verb existed, this README had
to start a `serve` just to put an asset in place — that wrinkle is gone.)

```bash
EXE=_build/native/debug/build/apps/cli/cli.exe
D=$(mktemp -d)
$EXE function-set create --file examples/sdf/01-map-mask-ssn/fns.json --data-dir "$D"
$EXE pipeline apply --data-dir "$D" --file examples/sdf/01-map-mask-ssn/spec.json
$EXE pipeline run   --data-dir "$D"        # == expected.txt
```

**Field-level version**: this case masks the digits of the whole line (as SDF's
`mask-user-pii` raw-text variant does). If you want to mask the `ssn` *field*
instead, `get(fromJSON(value), "ssn")` now publishes too — see
[case 12](../12-custom-serialization/) and README 决策 55.

**Difference worth knowing**: SDF's regex crate is not available to mbel
expressions (no regex builtin), so the body is ten nested `replace` calls. The
semantics match the sample; the *shape* of the solution is dictated by the
expression engine's builtin set, and that is a real difference, not a detail.
