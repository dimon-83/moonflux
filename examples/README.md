# examples/ — moonflux application cases

Runnable, gated ports of the [stateful-dataflow-examples](https://github.com/infinyon/stateful-dataflow-examples)
catalog onto moonflux. Every case is a frozen spec + input + expected output,
and `scripts/e2e-p29-examples.sh` runs all of them end to end and compares the
bytes — the examples are evidence, not illustration.

| case | SDF original | shape | gate leg |
| :--- | :--- | :--- | :--- |
| [01-map-mask-ssn](sdf/01-map-mask-ssn/) | `primitives/map`, `dataflows/mask-user-pii`, `packages/mask-ssn` | function-set asset + expr rule | 1 |
| [02-filter-questions](sdf/02-filter-questions/) | `primitives/filter` | sandboxed filter operator (1→0) | 2 |
| [03-filter-map-uppercase](sdf/03-filter-map-uppercase/) | `primitives/filter-map` | wasm filter → mbel rule chain | 3 |
| [04-flat-map-words](sdf/04-flat-map-words/) | `primitives/flat-map`, `dataflows/split-sentence` | sandboxed flat-map (1→N) | 4 |
| [05-split-two-streams](sdf/05-split-two-streams/) | `primitives/split/filter` | two ingress specs, disjoint filters | 5 |
| [06-merge-two-sources](sdf/06-merge-two-sources/) | `primitives/merge` | two ingress specs, one topic | 6 |
| [07-key-value-keys](sdf/07-key-value-keys/) | `primitives/key-value/*` | keys as a log column | 7 |
| [08-state-is-the-log](sdf/08-state-is-the-log/) | `primitives/update-state`, `dataflows/word-counter` | raw log vs applied topology; keyed compaction | 8 |
| [09-http-source](sdf/09-http-source/) | `dataflows/car-processing`, `dataflows/ny-transit`（入湖段，连接器在数据流之外） | HTTP source in the spec → filter → topic | 1 |
| [10-mqtt-transit](sdf/10-mqtt-transit/) | `dataflows/helsinki-transit`（入湖段） | MQTT subscription source (streaming) | 2–3 |
| [11-kafka-bridge](sdf/11-kafka-bridge/) | **无直接对应物**（示例集全是 topic→topic） | kafka source → filter → kafka sink, two brokers | 4–6 |

Run everything:

```bash
scripts/build-operators.sh                  # the filter/flat-map guests must exist
scripts/e2e-p29-examples.sh                 # 01–08: 8 legs, byte-exact, no network
scripts/e2e-p30-connector-examples.sh       # 09–11: 6 legs against local test peers
```

Everything runs locally with no network: cases 01–08 use files (plus one local
`serve` for case 1's asset deploy and case 8's applied topology), and cases 09–11
talk to **local test peers from this repo** — `python3 -m http.server`,
[`scripts/mqtt_test_broker.py`](../scripts/mqtt_test_broker.py) and
[`scripts/kafka_test_broker.py`](../scripts/kafka_test_broker.py) — which assert the
wire from the peer's side rather than from our client's opinion.

The mapping rationale, the semantic differences and the **gaps** (durable keyed
state, windows/watermarks, SQL, arrow-row state, the Rust SmartModule toolchain)
live in [`docs/sdf-examples-port.md`](../docs/sdf-examples-port.md). The
graphical side of SDF — Studio — is examined in
[`docs/sdf-studio-exploration.md`](../docs/sdf-studio-exploration.md).
