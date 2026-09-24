# 00 — P20 里程碑概览（Kafka 连接器）

**门禁（可证伪）**：`scripts/e2e-p20-kafka.sh` 全绿——对端是 `scripts/kafka_test_broker.py`
（stdlib、按 Kafka 规范说话、**校验我们产出的 RecordBatch 的 CRC-32C 并解析记录**）：往返
（文件 → kafka 汇 → broker 存储 → kafka 源 → stdout）逐字节一致；键保全；元数据/生产/Fetch
的形状被 broker 在线上字节上断言；版本不兼容与死 broker 都是结构化错误；一次性源语义不变。

**定位（重要，先读）**：Kafka 是 moonflux 的**对接生态对象（互操作端点）**，不是对标参考系统
——AGENTS §7 明确禁止把 Fluvio「或其同侪 Kafka」的默认假设无意识带入本项目的语义。本里程碑
只做**协议客户端**：用 Kafka 的线协议与真实 Kafka broker 对话，不改动 moonflux 自身的语义
（至少一次、无 leader epoch、默认未提交读等都照旧）。

**协议版本的权威来源**：开发期在 /tmp 装了 `kafka-python 3.0.11`（隔离安装，不进依赖、
不进门禁），从中提取并锁定了五个 API 的字段布局与 RecordBatch v2 结构；门禁对端（Python
迷你 broker）与客户端**双方按同一份规范实现**，为此用 **CRC-32C 已知检验向量**
（`"123456789"` → `0xE3069283`）作外部锚点——两边自洽地错是这种「两个实现都归我写」局面
的唯一真风险，检验向量把它钉住。开发期还用 kafka-python 直接解析我们产出的请求字节做对拍
（见 ticket 83 的证据）。

**锁定的版本与编码**（非 flexible、无 tagged fields；客户端启动先发 ApiVersions v0 探针，
断言 broker 支持这些版本，否则给出明确错误）：

| API | key | 我们用的版本 | 备注 |
| :--- | :--- | :--- | :--- |
| ApiVersions | 18 | v0 | 能力探针 |
| Metadata | 3 | v1 | broker 列表 + leader + is_internal |
| ListOffsets | 2 | v1 | timestamp −2 = earliest，−1 = latest |
| Produce | 0 | v3 | acks=1、timeout、RecordBatch v2 |
| Fetch | 1 | v4 | isolation_level=0、LSO 与 aborted_transactions 字段在 |

**已知边界（写成边界，不写 TODO）**：无压缩（带压缩 codec 的批返回**明确错误**并报出
codec）；**无消费组**（JoinGroup/SyncGroup/OffsetCommit 是另一个协议面——源直连分区，偏移在
客户端内存里记，重启按 `from` 策略重开）；无幂等/事务（producer_id = −1）；无 TLS/SASL；分区
默认 0（`?partition=N` 可指）。**真实 broker 互操作**在本环境不可得（无 Kafka/Redpanda、
docker 守护进程未运行）——Kafka 4.x 的 KIP-896 版本底线（Fetch ≥ v4、Produce 需更高）是否
满足留作有真 broker 时的冒烟项，已在文档明示。

**Tickets（依赖序）**
- 81 Kafka 线协议与客户端（crc32c 进 core/codec；apps/connectors/kafka.mbt：五 API 编解码 +
  RecordBatch v2 构建/解析 + 源/汇状态机）——无阻塞
- 82 spec 与接线（`KafkaSource`/`KafkaSink` + URL 校验 + pipeline/core-pipeline 映射）——阻塞于 81
- 83 门禁与文档（Python 迷你 broker + `e2e-p20-kafka.sh` + kafka-python 开发期对拍证据 +
  全部文档）——阻塞于 82

**状态**：达成（2026-09-23，`e2e-p20-kafka.sh` 5 腿全绿、全量 37/37；README 决策 44；矩阵 #24）。

**执行中抓到的三件事（留痕）**
- **请求也要 4 字节长度前缀**：客户端首发忘加，broker 把 api_key 当长度读、连接期挂住（门禁抓到的第一课）。
- **`"kafka://"` 是 8 个字符**：照 mqtt 的 7 切前缀会留一个前导 `/`，authority 变空（`parse_kafka_url` 与 `core/spec.kafka_url_ok` 同错同修；探针测试定位）。
- **「未知类型」夹具第三度踩雷**：spec 单测与金标语料里的示例又恰好用了 `"kafka"`——改 `kinesis` 并重生成语料；教训：新增已知类型时先 grep 全部夹具。
