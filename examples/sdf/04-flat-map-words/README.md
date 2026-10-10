# 04 · flat-map — sentence to words

**Ported from** `primitives/flat-map` and `dataflows/split-sentence`:
one sentence becomes N word records.

**What SDF does**: a Rust `flat-map` SmartModule returning `Vec<String>`.

**What moonflux does here**: `apps/operator-flatmap` (ABI v1) with
`{"separator": " "}`. Each emitted record keeps the source record's key,
timestamp and headers — the tokens are fragments of one event, not new events.

```bash
EXE=_build/native/debug/build/apps/cli/cli.exe
$EXE pipeline run --data-dir "$(mktemp -d)" --spec examples/sdf/04-flat-map-words/spec.json
```

**Offsets are the host's**: the guest never sees them (decision 15). On this
ingress path the sink sees the tokens in order; on a serve/fetch path each
source entry is chained individually, so fan-out siblings share their source
offset and the reply framing starts a new frame for each (P18) — a reader sees
the duplicate on purpose rather than a silently renumbered stream.
