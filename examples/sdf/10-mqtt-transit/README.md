# 10 · MQTT source — the ingest half of helsinki-transit

**Ported from** `stateful-dataflow-examples`: `dataflows/helsinki-transit`（无 broker 的 HSL
HFP 数据，字段 `vehicle`/`speed`/`route`/`tst` 取自该例的 `event` 类型）。

**Same mapping difference as case 09**: SDF 的 MQTT 连接器是**独立部署**（`mqtt-source`），
`dataflow.yaml` 里只有 `type: topic`；moonflux 的 MQTT 源就写在 spec 里。

**What the case does**: the repo's own MQTT 3.1.1 test broker
([`scripts/mqtt_test_broker.py`](../../../scripts/mqtt_test_broker.py)) pushes three events when the
subscriber arrives; the pipeline writes them to the topic and streams them to stdout. A
subscription is a **stream, not a pass** — the run stays subscribed until stopped, and the gate
asserts exactly that (it kills the run only after checking it was still alive).

```bash
EXE=_build/native/debug/build/apps/cli/cli.exe
python3 scripts/mqtt_test_broker.py --listen 127.0.0.1:20012 \
  --publish 'transit:{"vehicle":1001,"speed":32.5,"route":"1050","tst":"2026-01-01T08:00:00Z"}' \
  --publish 'transit:{"vehicle":1002,"speed":41.0,"route":"1051","tst":"2026-01-01T08:00:05Z"}' \
  --publish 'transit:{"vehicle":1001,"speed":35.5,"route":"1050","tst":"2026-01-01T08:00:10Z"}'
$EXE pipeline run --data-dir "$(mktemp -d)" --spec examples/sdf/10-mqtt-transit/spec.json   # Ctrl-C to stop
```

The gate additionally asserts the **wire**: the broker's facts file must show
`CONNECT` (clean session, role-named client id) and `SUBSCRIBE transit`.

**The gap this case stops at**: helsinki-transit's actual computation is a per-vehicle **average
speed** held in durable keyed state (`states:` + `update-state` + `average-speed-list`). moonflux
has no in-service keyed state (gap 1), so the port covers the ingest boundary and says so rather
than faking an aggregation. A windowed/stateful version is the P32 proposal in
[`docs/sdf-gap-closure-plan.md`](../../../docs/sdf-gap-closure-plan.md) §2.
