# 08 · state — the log is the state

**Ported from** `primitives/update-state` and `dataflows/word-counter` — the
family of SDF examples built on **durable keyed state** (`states:`,
`partition.assign-key`, `update-state`, tumbling windows).

**What SDF does**: a service mutates a keyed state object per event
(`temperature()` → mutate → `.update()?`), windows it in time, and reads it back
through `sql()` — cross-service reads included.

**What moonflux does here** — and this is the honest part — **it does not keep
service state**. What it has instead:

1. **The log is the durable state.** What the producer wrote is what is stored,
   replayable from offset 0 forever. `consume --data-dir` (the log view) shows
   the raw sentences; `consume --remote` against a server with the applied
   topology shows the words — one topic, two views.
2. **Keyed compaction is "latest value per key", materialized.** With keys
   stamped at ingress, `cluster compact` drops the superseded records and keeps
   the survivors **at their original offsets**.
3. **Aggregation is the reader's job.** Counting, windowing, averaging and joins
   are not in-stream operations here; a consumer (or the application) reads the
   replayed stream and keeps its own state.

```bash
EXE=_build/native/debug/build/apps/cli/cli.exe
D=$(mktemp -d)
# the keyed updates first: the log belongs to one writer per phase (P16)
for line in sensor-1=21 sensor-2=30 sensor-1=22; do
  printf '%s\n' "$line" > /tmp/one.txt
  MOONFLUX_ROLL_BYTES=20 $EXE produce --topic state --file /tmp/one.txt --key-separator '=' --data-dir "$D"
done
$EXE pipeline apply --data-dir "$D" --file examples/sdf/08-state-is-the-log/spec.json
$EXE serve --data-dir "$D" --listen 127.0.0.1:19901 &
$EXE produce --remote 127.0.0.1:19901 --topic sdf-08-sentences --file examples/sdf/08-state-is-the-log/input.txt
$EXE consume --remote 127.0.0.1:19901 --topic sdf-08-sentences --from 0 | cut -f4   # service view (words)
$EXE consume --topic sdf-08-sentences --from 0 --data-dir "$D" | cut -f4            # log view (sentences)
MOONFLUX_ROLL_BYTES=20 $EXE cluster compact --remote 127.0.0.1:19901 --topic state
$EXE consume --topic state --from 1 --data-dir "$D" | cut -f1,3,4                   # survivors, same offsets
```

**Two operational facts the case demonstrates rather than claims**:

- Compaction only touches **sealed** segments, and one `produce` is one append
  (one batch). Producing all three lines in a single call leaves them in the
  active segment and compaction correctly reports *0 segments, 0 records
  dropped*. The loop above produces one line per call with
  `MOONFLUX_ROLL_BYTES=20` so the first segments seal.
- After compaction the floor moves, and reading **below** it is a structured
  refusal (`OffsetOutOfRange` on stderr), not an empty window (P8). The
  survivors keep their own offsets — `--from 1` yields offsets 1 and 2.

**Gaps recorded, not faked** (see `docs/sdf-examples-port.md`): no durable
keyed state inside a service, no tumbling windows or watermarks, no SQL engine,
no arrow-row state, no cross-service state reads.
