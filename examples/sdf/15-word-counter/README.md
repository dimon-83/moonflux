# 15 · word-counter — keyed state, counted per word

**Ported from** `stateful-dataflow-examples` 的 `dataflows/word-counter`：它把句子切词、
按词去重、再用一个**有状态服务**累加每个词的出现次数。

**What moonflux does here**: the same three steps, with the state living where this
platform keeps state — a **keyed log the host caches**, not a service object:

```bash
EXE=_build/native/debug/build/apps/cli/cli.exe
$EXE pipeline run --data-dir "$(mktemp -d)" --spec examples/sdf/15-word-counter/spec.json
# 1 1 1 1 2 1 3 2 1 4 1
```

| step | SDF | moonflux |
| :--- | :--- | :--- |
| tokenize | `flat-map` | `apps/operator-wordkeys`（每个词成为记录的 **key**） |
| per-word count | `update-state` on a state service | `apps/operator-counter`（ABI v3：状态以数据进出） |
| where state lives | a service's own store | `spec.state.topic`（键控主题；宿主视图是缓存，启动时重放） |

**Faithfulness note**: SDF runs `dedupe` before the state update, so it emits one line
per *distinct* word per batch; we emit the running total on **every** occurrence, so the
stream shows the progression (`1 1 1 1 2 1 3 2 1 4 1`) and the **last** line for each
word is the same number SDF reports. `dedupe` is a separate primitive we have not built;
this example does not pretend otherwise.

**Why the running total is the honest output**: the counter is a *stateful operator*, and
its contract is "one record out per record in, carrying the new total". Emitting only on
change would be a second, different operator (a change-detector), and would need its own
gate — the same reason case 02 needed a guest operator to *drop* records.

**State is durable, and that is visible**: run the same spec twice against the same data
dir and the counts continue (`5 3 2 2 6 2 7 4 2 8 2`) because the host rebuilt its view by
replaying `word-counts`, not because anything stayed in memory:

```bash
$EXE consume --topic word-counts --from 0 --data-dir "$DATA"
# … one record per word per batch, each carrying the running total
```

The frozen expectations are `expected.txt` (first run), `expected-second-run.txt` (the
continuation) and `expected-state.txt` (the state topic's key/value pairs, sorted).
`scripts/e2e-p29-examples.sh` replays all three.
