# 09 · HTTP source — the ingest half of car-processing / ny-transit

**Ported from** `stateful-dataflow-examples`: `dataflows/car-processing`、`dataflows/ny-transit`
的**入湖段**（两例都用 InfinyOn 的 `http-source` 连接器周期拉取外部 API）。

**The mapping difference this case exists to show**: in SDF the connector is **not in the
dataflow** — every `sources:` entry in that catalog is `type: topic`, and the HTTP connector is a
separate deployment (`fluvio connector create --type http-source …`) whose only job is to move
outside data onto a topic. In moonflux the connector **is** the spec's source. Same data path,
different place to say it.

**What the case does**: a local `http.server` serves `cars.jsonl`; the pipeline fetches it once,
filters for one maker with the sandboxed filter operator, writes to the topic, and prints to
stdout. The gate asserts three independent things — the filtered stdout, that the **topic holds
all four raw records** (the log keeps what the connector delivered, not what the filter kept),
and that the server really logged the `GET`.

```bash
EXE=_build/native/debug/build/apps/cli/cli.exe
D=$(mktemp -d); cp examples/sdf/09-http-source/cars.jsonl "$D"/
(cd "$D" && python3 -m http.server 20011 &)          # serves cars.jsonl for the fixture URL
$EXE pipeline run --data-dir "$(mktemp -d)" --spec examples/sdf/09-http-source/spec.json
$EXE consume --topic sdf-09-cars --from 0 --data-dir <same data dir> | cut -f4
```

**Two honest differences**:
- **One GET, not a poll.** SDF's `http-source` connector re-fetches on an interval; our HTTP
  source is one-shot (`pull` returns `Exhausted` after the first body). A `interval_ms` source
  option is a queued small ticket (see [`docs/sdf-gap-closure-plan.md`](../../../docs/sdf-gap-closure-plan.md) §2 缺口 9).
- **Substring filter, not a field filter.** Selection here is `contains "maker":"Ford"` over the
  raw JSON text, because `fromJSON(value)` is rejected by the publish-time static check (it probes
  `value` with the literal `"a"`) — that is the gap-4 finding, with a one-place fix queued. Field
  access exists in the engine today (`toJSON(fromJSON("{\"a\":1}"))` works); only the probe blocks it.
