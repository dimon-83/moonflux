# 02 — 线协议 Record/Batch 编解码 + golden vectors

**What to build:** moonflux 的自建线协议 v1 的 Record 与 RecordBatch 帧：编码为字节流、从字节流解码（含 CRC 完整性校验、截断/损坏检测）。golden vectors 以数据文件为真相源（`testdata/protocol_vectors.json`），通过脚本生成检入的 MoonBit 测试数据模块；解码器对向量做字节级对拍（encode(bytes) 与 decode(bytes) 双向）。日志段文件与网络帧共用同一帧格式，保证"日志文件即协议流"。

**Blocked by:** 01.

**Status:** ready-for-agent

- [ ] `core/protocol` 包：Record（timestamp/key/value/headers）与 RecordBatch（baseOffset/batchLength/partitionLeaderEpoch?→v1 从简、crc、recordCount、records）的 encode/decode；错误一律 Result/suberror，显式校验长度与索引边界
- [ ] 帧格式版本化：magic + version 字段在帧头；未知版本拒绝并报错
- [ ] golden vectors：`core/protocol/testdata/protocol_vectors.json`（真相源）+ `tools/gen_protocol_vectors.py` 生成 `core/protocol/vectors_gen.mbt`；向量覆盖：空批、单记录、多记录、空 key/value、非 UTF8 安全字节、多 headers、跨 varint 边界的大值
- [ ] 对拍：每个向量 decode(encode(records)) == records 且 encode(records) == 向量字节；损坏注入（翻转 crc、截断）必须报错
- [ ] `moon test` 双后端（native + wasm-gc）通过
