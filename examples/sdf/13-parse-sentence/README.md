# 13 · parse-sentence — the package's two functions, end to end

**Ported from** `stateful-dataflow-examples`: `packages/parse-sentence`，它的两个函数是
`sentence-to-words`（`flat-map`：句子 → 词）与 `word-length`（`map`：词 → 长度）。

**What moonflux does here**: the same two steps, each in the layer that can express it —
`apps/operator-flatmap` does `sentence-to-words` (1→N, sandboxed), and the mbel rule
`string(len(value))` does `word-length`. The `string(...)` wrapper is not decoration: a
rule transform **must return a string** (README decision 30), so a length is only a valid
rule result once it is stringified — `len(value)` alone is rejected at publish time with
"transform must return a string", which is the same discipline that made case 02 need a
guest operator for *dropping* records.

```bash
EXE=_build/native/debug/build/apps/cli/cli.exe
$EXE pipeline run --data-dir "$(mktemp -d)" --spec examples/sdf/13-parse-sentence/spec.json
# This is a test -> 4 2 1 4
```

**Faithfulness note**: SDF's package emits a typed `u32` length per word; we emit the
decimal text of that length. Same information, different carrier — and the carrier is
forced by the rule contract, not chosen for convenience.
