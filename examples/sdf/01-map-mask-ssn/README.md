# 01 · map — mask the digits of an SSN

**Ported from** `stateful-dataflow-examples`:
`primitives/map`（mask `ssn`）、`dataflows/mask-user-pii`（raw 文本掩码）、
`packages/mask-ssn`（可复用函数资产）。

**What SDF does**: a `map` SmartModule written in Rust with the `regex` crate
replaces every digit with `*`; the package variant reuses the same function
through `imports: pkg: example/mask-ssn@0.1.0`.

**What moonflux does here**: the same masking as an **mbel function-set asset**
(`fns.json`, set `pii`, function `mask_ssn`) referenced by name from the spec —
the platform's counterpart of an SDF package. The function set is deployed to a
node, so the case installs it through a running `serve` (the CLI has no local
`--data-dir` create verb) and then runs the pipeline locally against the same
data dir.

```bash
EXE=_build/native/debug/build/apps/cli/cli.exe
D=$(mktemp -d)
$EXE serve --data-dir "$D" --listen 127.0.0.1:19901 &
$EXE function-set create --remote 127.0.0.1:19901 --file examples/sdf/01-map-mask-ssn/fns.json
$EXE pipeline apply --data-dir "$D" --file examples/sdf/01-map-mask-ssn/spec.json
$EXE pipeline run   --data-dir "$D"        # == expected.txt
```

**Difference worth knowing**: SDF's regex crate is not available to mbel
expressions (no regex builtin), so the body is ten nested `replace` calls. The
semantics match the sample; the *shape* of the solution is dictated by the
expression engine's builtin set, and that is a real difference, not a detail.
