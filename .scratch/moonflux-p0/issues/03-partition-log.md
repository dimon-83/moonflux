# 03 — 分区日志：接口 + 内存实现

**What to build:** 单分区 commit log 的内核逻辑：以注入的存储句柄（函数字段式接口注入，不引入 IO 类型）为参数的 SegmentedLog——append（分配 offset、成批落盘）、read（从指定 offset 读取至多 N 条）、high watermark；内存实现直接可测，文件实现由 04/05 通过同一接口注入完成。内核零 IO 红线保持：core/log 只见 Bytes 与注入句柄。

**Blocked by:** 02.

**Status:** ready-for-agent

- [ ] `core/log` 包：`SegmentFile` 注入接口（read/append/flush/size，Result 返回）；`MemorySegment` 实现（供测试与 wasm 后端复用）
- [ ] SegmentedLog：append(records)→baseOffset、read(from, maxRecords)→batches、highWatermark；offset 单调性、批量原子性（CRC 校验失败即停，返回已确认水位）
- [ ] 恢复逻辑（纯计算）：从字节流扫描合法批序列，忽略尾部半批/损坏批（崩溃恢复语义），返回恢复后的 log end offset
- [ ] 单元测试：顺序写读、随机偏移读、损坏注入、恢复截断；双后端通过
