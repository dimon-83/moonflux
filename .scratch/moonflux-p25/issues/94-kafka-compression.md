# 94 — Kafka 连接器按压缩列行动

**What to build:** RecordBatch v2 的压缩列（attributes 位 0-2）不再是统一拒绝：gzip 批
**解压后解析**（上界 = MAX_BATCH_BYTES 单一预算）；snappy/lz4/zstd **仍按名拒绝**；产生端
`?compression=gzip`（默认不变，P20 的字节一致形状保持）。spec 校验放行 compression=
gzip|none，未知 codec 在 apply 期按名拒绝。

**Status:** done (2026-09-25)

- [x] 产生端：build_batch(records, now, gzip)；records 段 gzip 容器压缩，CRC 覆盖压缩后字节
- [x] 消费端：CRC 先行（覆盖压缩字节），inflate 后逐记录解析；records_reader 双路绑定
- [x] broker 扩展：`--compress-gzip`（存储前重建为 codec 1 批，Python gzip 容器）+
      消费端 inflate（gzip/zlib 容器都收）+ fact 行记录**收到批的实际 codec**
- [x] wbtest：说谎批（声称 gzip 实未压）在容器处拒绝、snappy 按名拒绝、自建 gzip 批往返
- [x] 门禁 `scripts/e2e-p25-compression.sh`（4 腿）：我们的压缩器过 Python 解压审判、
      Python 压缩器过我们解压审判、默认不变、apply 期拒绝
- [x] 文档：AGENTS P25 行 + P15 纪律块补压缩一句；README 决策 49；feature-matrix 第 20 行；
      compatibility-matrix #24 补证据；user-guide Kafka 节；roadmap + 看板
