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

**Polling** (`spec-poll.json`, `interval_ms: 200`): the same source with an interval re-fetches,
which is the SDF `http-source` shape. The pull contract is the difference that matters —
a poller says `Quiet` ("nothing right now") and **never** `Exhausted` ("nothing ever"), so the
run stays a connector process. Re-fetching an unchanged body re-delivers the same records:
**deduplication is the reader's problem**, exactly as it is for any external poller.

```bash
# the polling shape: keep it running, stop it yourself
$EXE pipeline run --data-dir "$(mktemp -d)" --spec examples/sdf/09-http-source/spec-poll.json
```

**One honest difference left**:
- **Raw text, not typed fields.** SDF's connector emits records its schema declares; ours
  delivers the body's lines as opaque records, and structure is the expression's business
  (`get(fromJSON(value), "maker")`, see [case 12](../12-custom-serialization/)).
- **Substring filter, not a field filter.** Selection here is `contains "maker":"Ford"` over the
  raw JSON text, because `fromJSON(value)` is rejected by the publish-time static check (it probes
  `value` with the literal `"a"`) — that is the gap-4 finding, with a one-place fix queued. Field
  access exists in the engine today (`toJSON(fromJSON("{\"a\":1}"))` works); only the probe blocks it.
