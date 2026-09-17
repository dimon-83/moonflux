# 40 — 数据节点多分区宿主

**What to build:** spu 的 `PartitionHost`（单主题、partition 0 硬编码）换成**宿主表**：一个节点同时持有
若干 `(topic, partition)` 宿主，每个宿主有自己的 `ledger` / `leader_addr` / `replicas` / `caught_up`。
节点**从控制面学习自己的分配**（不能自己拼：放置是 SC 调和出来的真相）——心跳应答携带该节点的分配列表
（与 P3「提名是状态、随 CMD_LEADER 应答下发」同构）。生产/拉取/SYNC_FETCH/SYNC_ACK/OFFSET_INFO 全部按
`(topic, partition)` 路由到宿主。

**Blocked by:** None.

**Status:** done (2026-09-17)

- [x] `core/client/protocol.mbt`：`AssignmentView{topic, partition, leader, replicas, nominated}` +
      `encode_assignments` / `decode_assignments`（心跳应答载荷；空列表 = 无分配）
- [x] `apps/cli/node.mbt`：`HostTable`（`Map[label] -> 宿主单元`；`PartitionHost` 增 `partition : Int`，
      全部 `PartitionRef` 由宿主自己带出，删掉 `partition: 0` 字面量）
- [x] 宿主生命周期：心跳应答 → 建/更新宿主（`adopt_view`）/ 撤销不再分配的宿主（关日志、清账本，日志保留）
- [x] spu 家务 tick 改为**逐宿主**：问 leader（`CMD_LEADER` 带该分区 ref）→ `adopt_view` /
      `take_nomination`（候选自提升）→ 复制或维持（`replicate_once`）；`CMD_CONFIRM` 带该分区 ref
- [x] 数据面：`CMD_PRODUCE`/`CMD_FETCH`（无分区字段）→ `(applied topic, 0)`；`CMD_PRODUCE_PARTITION`/
      `FETCH_PARTITION`/`SYNC_*`/`OFFSET_INFO` → 按请求里的 `PartitionRef` 找宿主（找不到 = 结构化错误）
- [x] 单测：宿主表的建/更新/撤销；按 ref 路由命中与未命中

### 关账（2026-09-17）

落地：`core/client/protocol.mbt`（`AssignmentView` 编解码 + `encode_node_full`/`decode_node_full` 的每分区段 +
`PartitionReport`）、`apps/cli/node.mbt`（`HostTable` + `adopt`/`retain`/`ensure`/`reports`/`tick_one` +
控制面分配下发 `PlacementState::assignments_for` 随心跳应答 + 数据面按 `(topic,partition)` 路由 +
`CMD_HELLO` 交给同一分发器 + **spu 数据端口改用 ConnectionHub**）。单测：`core/client` 报告/分配编解码往返与
截断、`apps/cli` 宿主路由（间接由 E2E 覆盖）。

**过程中的三个实测结论**（都写进了 README 决策 29/30）：
① 阻塞式 accept 的超时决定了整个节点的响应延迟（500ms × 每次 poll → 客户端看到 1.0–1.5s）；
② 单线程节点间同步调用在环状拓扑下互相失聪 → 改为协作式等待；
③ 一个节点的周期超过 3s 存活超时会被控制面判死 → 假选举（修复前实测复现）。
