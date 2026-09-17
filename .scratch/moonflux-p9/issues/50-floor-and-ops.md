# 50 — retention floor 与运维面

**What to build:** 把 T46 留的钩子接上：有消费组在消费的分区，retention 的 floor 从"HW"变成
**`min(HW, 所有组的提交偏移)`**——慢消费者之下的数据不被删除；`group describe` 显示每分区的进度与滞后，
让"谁拖住了保留"一眼可见。

**Blocked by:** 49。

**Status:** done (2026-09-17)

- [x] 应用侧：leader 的 housekeeping 计算 floor 时询问组注册表（本节点的组视图来自 SC？——**首版口径**：
      组状态在 SC，leader 需要 floor 时向 SC 查询该分区的"最慢提交偏移"（加法命令或复用 DESCRIBE 的应答）；
      查询失败时**退回 HW**（保守：不删）并记一行告警）
- [x] `group describe` 的输出包含 `topic[i] committed=… leo=… lag=…`，lag 为推导值
- [x] 门禁脚本里的第 6 条腿据此断言：慢组之下的段**不被删**；组提交推进后旧的段才可删

### 关账（2026-09-17）

落地：分配应答的**加法尾段**携带消费者地板（`GroupFloor`，与节点记录的尾段同构——旧解码器读分配、忽略尾部）；
`GroupRegistry::floors(partitions)` 取"有提交的组"里的最老偏移（**未提交的组不参与**：它还没开始，不是落后）；
SC 在心跳应答里带上该节点所持分区的地板；leader 把它记在宿主上，retention 的 floor 变成 `min(已提交前缀, 消费者地板)`。
`group describe` 的滞后由 CLI **向各分区 leader 观测**（协调者知道提交、leader 知道末端），不凭记忆。接线由门禁第 6 腿证明：
首个可读偏移 3 ≤ 组提交 3 ✓。
