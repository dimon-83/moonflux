# 81 — P20 Kafka 线协议与客户端

**What to build:** `core/codec` 增 **CRC-32C（Castagnoli）**（纯计算、已知检验向量钉住——
Kafka 要的是它，不是 core 已有的 IEEE crc32）；`apps/connectors/kafka.mbt`：五个 API 的
请求/应答编解码（版本锁定见 overview 的表）、RecordBatch v2 的**构建与解析**、zigzag
varint/varlong 辅助、`kafka_sink` 与 `kafka_source` 状态机。

**布局要点（来自 kafka-python 3.0.11 提取，代码里逐字段注明）**：
- 请求头 = api_key i16 / api_version i16 / correlation_id i32 / client_id 字符串；应答头 =
  correlation_id i32；字符串 = i16 长度 + utf8；数组 = i32 计数；Bytes = i32 长度 + 原始字节。
- RecordBatch v2 头 61 字节：baseOffset i64 / batchLength i32（= 总长 − 12）/ leaderEpoch i32 /
  magic=2 / crc u32 / attributes i16 / lastOffsetDelta i32 / firstTimestamp i64 / maxTimestamp i64 /
  producerId i64（−1）/ producerEpoch i16（−1）/ baseSequence i32（−1）/ **records 计数 i32**；
  **CRC 覆盖 attributes 起（偏移 21）到末尾**（baseOffset 与 batchLength 不在其内——这正是
  broker 能改写 baseOffset 而不重算 CRC 的原因）。
- 记录：length（zigzag varint，覆盖其后全部）/ attributes i8 / timestampDelta（zigzag varlong）/
  offsetDelta（zigzag varint）/ keyLen（zigzag varint，−1 = null）/ key / valueLen / value /
  headers 计数（zigzag varint）。
**所有记录级 varint 是 zigzag**（kafka-python `encode_varint` = `(v<<1)^(v>>63)`，已核）。

**Blocked by:** 无。

**Status:** done (2026-09-23)

- [x] `core/codec`：`crc32c`（表驱动，reflect 0x82F63B78）+ wbtest（`"123456789"` → `0xE3069283`、
      空串 → 0、分段复合律）——内核纯函数，全后端可编译
- [x] `apps/connectors/kafka.mbt`：zigzag 编解码、Kafka 基本类型读写（i16/i32/i64/string/bytes/
      数组）、五个 API 的请求构建与应答解析（含错误码到文本的映射）
- [x] RecordBatch v2：`build_batch(records, base_ts)`（单批、无压缩、producer_id −1、
      偏移 delta 0..n−1）与 `parse_batches(bytes)`（多批串联、CRC 校验、压缩 codec 检出即
      明确报错）
- [x] `kafka_sink`：lazy 连接 → ApiVersions 断言 → Metadata 取 leader/分区 → 逐批 Produce
      （acks=1）→ 应答错误码检查
- [x] `kafka_source`：lazy 连接 → Metadata → ListOffsets（`from=earliest|latest|<n>`）→ Fetch
      循环（max_wait_ms 300ms 作 Quiet 窗；解析批 → 记录带 key/timestamp；无数据 = `Quiet`）
- [x] URL：`kafka://host:port/topic[?partition=N&from=...]` 解析与拒绝（缺 topic/非法分区/非法
      from）
- [x] wbtest：crc32c 向量、zigzag 往返与边界、批构建→解析往返（含空批/空值/null 键）、URL 解析
