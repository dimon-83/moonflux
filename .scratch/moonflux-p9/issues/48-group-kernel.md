# 48 — 组语义内核

**What to build:** `core/group`：纯计算的消费组语义——成员集合 + 存活推导、**世代（epoch）**、
**range 分配**（确定性）、**提交围栏**（提交必须带当前 epoch，过期即结构化拒绝）、**续读点**查询、
以及给 retention 用的**安全下界**。零 IO、零时钟（`now_ms` 由调用方传入），全后端可编译。

**Blocked by:** None.

**Status:** done (2026-09-17)

- [x] 类型：`GroupMember{ id, address, last_seen_ms }`、`GroupState{ group, epoch, members, committed, topics }`、
      `GroupError{ StaleEpoch, UnknownMember, UnknownPartition, Regression, ... }`
- [x] `observe_member(state, member, now_ms, timeout_ms)`：加入/续期/清扫过期（与 NodeTable 同构：存活是推导的，
      过期只报一次）；任何成员集合变化 → `epoch += 1` 并返回"世代变了"
- [x] `assign(topic, partitions, members) -> Array[(member_id, Array[partition])]`：**range** —— 成员按 id 排序、
      分区按序切成连续段，成员数 > 分区数时多出的成员分到空集（确定性：同一输入永远同一输出）
- [x] `commit(state, member_id, epoch, partition, offset)`：**围栏**（`epoch != state.epoch` → `StaleEpoch`）、
      成员必须在册、**偏移只能前进**（回退 → `Regression`，因为回退会重复消费且掩盖 bug）
- [x] `resume_offset(state, partition) -> Int64`（未提交过 = 0）、`retention_floor(state, partition, hw) -> Int64`
      （= `min(hw, 该组在该分区的提交偏移)`；无提交 = hw —— 与 T46 的约定一致）
- [x] 单测：分配确定性（打乱输入顺序结果不变）、成员加入/离开导致的重分配、围栏拒绝、偏移回退拒绝、
      floor 计算、清扫只报一次

### 关账（2026-09-17）

落地 `core/group`（内核包，零 IO、零时钟、四后端可编译）：`GroupMember`/`CommitRecord`/`GroupState` +
`observe_member`/`declare_topics`/`sweep`/`assign`/`assignment_of`/`commit`/`resume_offset`/`retention_floor`/`lag`；
结构化错误 `StaleEpoch`/`UnknownMember`/`NotAssigned`/`Regression`。分区身份复用 `core/cluster.PartitionId`（同一
协调面概念，不另造一份）。

**三条设计决定（写进代码注释）**：① **成员存活是推导的**（与节点表同构）：只存 `last_seen_ms`，超时即离开，
离开只报一次；② **epoch 是成员集合的世代**——只有"谁持有什么"变化才换代（重复上报不换），提交必须带它，
过期即 `StaleEpoch`；③ **分配是 (成员集合, 分区集合) 的纯函数**（range：成员按 id 排序、分区按序切连续段、
余数给最早成员）——同一成员集合永远同一结果，与上报顺序无关，因此再平衡可复现、可评审。

**测试**（`core/group_test` 4/4）：分配确定性与均衡（5/3 分区、打乱输入一致、成员多于分区时空手）、
成员变更换代与静默离场只报一次、**提交围栏**（过期 epoch 拒、非成员拒、非持有分区拒、回退拒、同值幂等）、
以及 **floor 合流**（无进度时=HW；落后时=提交偏移；超前时不吃亏）与滞后推导。
