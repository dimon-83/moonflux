# 41 — 每分区水位上报与按分区选主

**What to build:** 每个宿主的 LEO 要能让 SC 看见——否则选主只能拿一个"节点级"数字当所有分区的进度。
节点记录的载荷**加法扩展**：尾部追加可选的每分区 LEO 段（`decode_node` 不校验读尽，故新旧都能读；
新解码器缺段时得空列表）。SC 的 `NodeTable` 保存每分区 LEO，`elect_fallen_leaders` 的 yardstick
读**该分区**的 LEO，而不是节点级那个数字。

**Blocked by:** 40.

**Status:** done (2026-09-17)

- [x] `core/client/protocol.mbt`：`PartitionReport{topic, partition, leo}` +
      `encode_node_full(record, reports)` / `decode_node_full`（`encode_node`/`decode_node` 保持原语义 = 空段，
      旧行为不变）；`NodeRecord.leo` 语义**写明**：宿主里的 `(applied topic, 0)` 的 LEO，没有则 0（兼容字段，
      每分区真相在段里）
- [x] `apps/cli/node.mbt`：上报时填每分区 LEO（逐宿主读日志末端）；`NodeTable` 存 `Array[PartitionReport]`
- [x] `elect_fallen_leaders`：progress 从"该分区的 LEO 报告"构造（缺报告 = 0），不再读 `record.leo`
- [x] `cluster nodes` 输出保持不变（节点级 leo 仍是兼容字段）；`cluster offsets --partition N` 走宿主账本
- [x] 单测：解码器兼容（无段/有段）、选主读分区 LEO（构造两个分区进度不同的表）

### 关账（2026-09-17）

落地：节点记录尾部**加法段**携带每分区 LEO（旧解码器不校验读尽、新解码器缺段为空表——两个方向都有单测），
`NodeTable` 保存 `reports` 并提供 `leo_of`，`elect_fallen_leaders` 的 yardstick 读**该分区**的 LEO，
`NodeRecord.leo` 保留为兼容字段（文档写明语义）。

**顺带修复**：`cluster leader` 之前硬编码 `partition: 0`，`--partition` 被忽略（多分区运维面因此看不到真相）；
现在与 `cluster offsets` 共用 `parse_partition_flag`。
