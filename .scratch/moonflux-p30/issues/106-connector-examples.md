# T106 · 连接器与外部数据案例（examples/sdf/09–11 + P30 门禁）

**What to build**: 三个外部数据案例与它们的端到端门禁。
1. `09-http-source`（SDF `car-processing`/`ny-transit` 入湖段）：spec 内的 HTTP 源 → 沙箱过滤 → 主题 → stdout；断言三件事——过滤后的 stdout、**主题保留四次原始抓取**、HTTP 服务端日志里确有那次 `GET`。
2. `10-mqtt-transit`（SDF `helsinki-transit` 入湖段）：spec 内的 MQTT 订阅源（流式，不停机）；断言交付顺序、主题内容、以及 **broker 侧事实**（CONNECT clean + SUBSCRIBE transit）。
3. `11-kafka-bridge`（示例集无对应物：其数据流全是 topic→topic，连接器在数据流之外）：`file → kafka`（broker A）作种子，`kafka → filter → kafka`（broker B）作桥；断言读 **broker B 自己的 received 文件**，并要求 produce facts 是 `acks=1 crc=ok`。

**Why these three**: 它们把"连接器在哪说话"这条落差演示清楚——SDF 的连接器是独立部署，moonflux 的连接器就在 spec 里；同时三条都用**仓库自带的独立测试对端**，不需要外网。

**Blocked by**: 无（HTTP/MQTT/Kafka 源与汇在 P1/P19/P20 已就位）。

**Status**: ✅ 2026-10-10（门禁 6 腿绿；本地 + CI `full` 均绿）

**Checklist**:
- [x] 三例夹具（cars.jsonl / events.jsonl / orders.jsonl）+ spec + expected
- [x] `scripts/e2e-p30-connector-examples.sh`：6 腿（HTTP 源/主题/服务端日志、MQTT 源/主题/线上事实、Kafka 入/桥/线上事实）
- [x] 每例 README 写明 SDF 出处、运行命令、诚实差异（一次性 GET 而非轮询；子串过滤而非字段过滤；helsinki 的均值聚合属缺口 1）
- [x] 纳入 `scripts/gates.sh`（45 → 46 步）并同步全部计数
- [x] `examples/README.md` 索引 + `docs/sdf-examples-port.md` 案例表与缺口 9 状态 + `docs/sdf-gap-closure-plan.md` 进展
