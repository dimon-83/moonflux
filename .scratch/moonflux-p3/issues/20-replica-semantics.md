# 20 — 复制语义与副本角色状态机（纯计算）

**What to build:** `core/replica`：对标的复制语义，全部纯计算、可单测 —— 这是 P3 门禁
（水位一致性）的**真相源**，真实节点只是它的驱动者。

**Blocked by:** None（与 19 并行）。

**Status:** ✅ done (2026-09-16)

- [x] LEO/HW 账本：`ReplicaProgress{ spu, leo }`；`compute_high_watermark(leader_leo, progress[])`
      = **各副本 LEO 的最小值**（含 leader 自身）；**HW 单调不回退**（断言推进不倒退）
- [x] LRS 成员判定：`lrs_members(progress, leader_leo, max_lag)` —— 滞后 > 阈值的副本移出 LRS
      （**但仍收记录**，只是失去选举资格），追上自动回归；阈值随 Spec/预算可配
- [x] `OffsetInfo{hw, leo}` + 读钳制：`read_limit(info, mode)` → Committed 取 hw、Uncommitted 取 leo；
      **默认 Uncommitted**（对标事实）；越界读报结构化错误
- [x] 角色状态机：`Follower → Candidate → Leader → Follower`；转换合法性显式校验
      （例如未收到提名不得自我提升）；**无 epoch**：状态里没有任期字段（结构性不变量）
- [x] 选主候选：`elect_candidate(progress, lrs, offline_leader)` → 最小滞后者；候选耗尽 → `Offline`
- [x] 分歧处理规则（本项目显式定义）：`resolve_rejoin(local_leo, leader_leo)` → 若 local > leader
      则 `TruncateTo(leader_leo)` 且**报告丢弃量**；否则 `CatchUp`
- [x] 单测：HW=min(LEO) 含 leader；水位不回退；滞后进出 LRS；读钳制两模式；非法角色转换被拒；
      候选耗尽 → Offline；分歧处理报告；双后端

## 落地记录

- 实现：`core/replica`（`replica.mbt`）——`ReplicaProgress`、`ProgressLedger`、
  `LrsPolicy`/`DEFAULT_MAX_LAG`、`OffsetInfo`、`ReadMode`、`Role`/`ReplicaState`、
  `Nomination`、`RejoinPlan`；函数 `new/observe/advance_leader/high_watermark/offset_info/
  lrs_members/has_vote/read_limit/check_read/promote/follow/resolve_rejoin/elect_candidate/lag_of`。
- **HW = min(LEO) 含 leader 自身**；`observe` 单调（迟到/乱序的低 LEO 报告被忽略，绝不让水位回退）；
  未在副本集合中的上报被拒（副本集合是控制面决定，不能被上报扩宽）。
- **LRS 是计算而非存储**：`lrs_members` 每次按 lag 阈值现算 ⇒ 落后即失去投票权、追上自动回归，
  且**移出 LRS 不停止收记录**（语义上仍留在副本集合）。
- **无 epoch 是结构性不变量**：`Role`/`ReplicaState` 里没有任期字段（不是漏了）。
- **提名门槛**：未收到提名不得自我提升（`promote` 拒绝候选人不匹配的提名）；已是 leader 再提升报错。
- **分歧处理（本项目显式定义）**：`resolve_rejoin(local, leader)` → `local > leader` 则
  `TruncateTo(leader)`，否则 `CatchUp(local)`；即**新 leader 的 LEO 是唯一权威**（参考系统无
  epoch 截断可依，此规则待写入 README 决策记录，属 26 号 ticket）。
- 测试：`core/replica_test`（13 项）——HW 语义、水位不回退、LRS 进出、读钳制两模式、
  非法提升被拒、自降、回归计划三态、提名最小滞后者、离线 leader 不作候选；双后端绿。
