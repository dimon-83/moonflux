# 19 — 控制面数据模型 + level-triggered 调和（纯计算）

**What to build:** `core/cluster`：控制面的内核侧。声明式 Spec（Topic：分区数 / 副本因子；
Spu：节点身份与地址）+ 集群**期望状态 → 实际状态 → 动作清单**的调和。调和必须是
level-triggered（只看当前期望与实际的差异，不看事件历史）、幂等（同一输入重复跑得到同一动作
或空动作）、确定性（无时钟无随机，注入式）。

**Blocked by:** None.

**Status:** ✅ done (2026-09-16)

- [x] `core/cluster` 包：`ClusterSpec{ topics, spus }`、`PartitionId{topic, index}`、
      `ReplicaSet{ partition, leader?, replicas[], lrs[] }`、`ClusterState`（实际状态）
- [x] `reconcile(state, spec) -> Array[Action]`：纯函数，输入相同则输出相同；
      动作是声明（`PlacePartition` / `AssignLeader` / `AddReplica` / `RemoveReplica`），不含 IO
- [x] 放置规则：副本分散到不同 Spu（机架感知留字段不实现）；副本因子 ≤ 可用节点数（否则报错）
- [x] `Action` 的稳定排序（可对拍：同一输入的动作序列字节级可比较）
- [x] 单测：收敛性（期望=实际 → 空动作）、幂等（重复调和空动作）、节点增减的放置变化、
      副本因子越界报错；双后端（native + wasm-gc）

## 落地记录

- 实现：`core/cluster`（`cluster.mbt`）——`SpuSpec` / `TopicSpec` / `ClusterSpec` /
  `PartitionId` / `ReplicaSet` / `ClusterState` / `Action` / `ClusterError`；
  `validate_spec`、`reconcile`、`apply_actions`、`canonical_state`、`place`。
- **放置算法**：FNV-1a(topic) 掩码取非负 → 在**节点 id 排序后**的列表上按 `(hash + index) % n`
  起走 rf 步 ⇒ 与声明顺序无关（同名 spec 必然同布局）、副本互异、跨分区轮转。
  机架感知留字段不实现（报告 §1.2.6-A）。
- **调和契约**：只依赖 `(state, spec)`；收敛后动作数组为空；动作顺序稳定（topic 名 →
  分区 index → 动作种类）。`apply_actions` 是调和的逆运算（放内核里，"调和+应用"可无节点单测）。
- **动作集**收敛为三个：`PlacePartition` / `AssignLeader` / `RemovePartition`
  （ticket 里写的 AddReplica/RemoveReplica 未单列——节点增删表现为副本集合整体重塑 +
  leader 必要时改派；少一个动作种类 = 少一处可漂移的语义）。
- **初始 leader 规则**（本项目定义，参考系统只规定了"变更时怎么选"）：副本集合中的**第一个**
  节点；节点退出导致 leader 不在集合内时改派给新集合第一个。
- 测试：`core/cluster_test`（9 项）——放置/收敛/幂等/顺序无关/节点增删/topic 移除/校验错误分类；双后端绿。
- 踩坑留痕：`UInt → Int` 转换会得到负数（FNV 哈希），直接当索引会越界 abort ⇒ 掩码 `& 0x7FFFFFFF`。
