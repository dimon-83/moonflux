# 11 · Kafka bridge — kafka → filter → kafka across two brokers

**No direct SDF counterpart, on purpose.** The example catalog never names a connector: its
dataflows are topic-in/topic-out and the outside world arrives through separately deployed
connectors. This case is the **other half** of that picture — a pipeline whose source *and* sink
are an external system's protocol, with a transformation in between.

**What the case does** (both brokers are the repo's independent implementation,
[`scripts/kafka_test_broker.py`](../../../scripts/kafka_test_broker.py), so nothing needs the network):

1. `seed-spec.json` — file source → **Kafka sink** on broker A (`orders-in`), which is how records
   come to exist on an external broker at all.
2. `bridge-spec.json` — **Kafka source** on broker A → sandboxed filter (`"status":"paid"`) →
   **Kafka sink** on broker B (`orders-paid`).
3. The assertions read **broker B's own received file**: exactly the two paid orders, nothing else.
   Both brokers' facts also confirm the sink speaks real Kafka (`acks=1`, `crc=ok`, `codec=none`).

```bash
EXE=_build/native/debug/build/apps/cli/cli.exe
python3 scripts/kafka_test_broker.py --listen 127.0.0.1:20013 --topic orders-in \
  --received /tmp/orders-in.txt &
python3 scripts/kafka_test_broker.py --listen 127.0.0.1:20014 --topic orders-paid \
  --received /tmp/orders-paid.txt &
$EXE pipeline run --data-dir "$(mktemp -d)" --spec examples/sdf/11-kafka-bridge/seed-spec.json
$EXE pipeline run --data-dir "$(mktemp -d)" --spec examples/sdf/11-kafka-bridge/bridge-spec.json  # Ctrl-C
cut -f2 /tmp/orders-paid.txt    # == expected-paid.txt
```

**Boundaries kept as boundaries** (same as the P20 connector discipline): no consumer groups (the
source's offset is the URL's `from`), no idempotence/transactions (`producer_id = −1`), `acks=1`,
no TLS/SASL, and no compression on the produce side. The brokered topic is not a moonflux topic —
the moonflux topic (`sdf-11-orders-*`) is where the *log* half of the pipeline lives.
