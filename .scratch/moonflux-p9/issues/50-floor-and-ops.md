# 50 — retention floor 与运维面

**What to build:** 把 T46 留的钩子接上：有消费组在消费的分区，retention 的 floor 从"HW"变成
**`min(HW, 所有组的提交偏移)`**——慢消费者之下的数据不被删除；`group describe` 显示每分区的进度与滞后，
让"谁拖住了保留"一眼可见。

**Blocked by:** 49。

**Status:** ready-for-agent

- [ ] 应用侧：leader 的 housekeeping 计算 floor 时询问组注册表（本节点的组视图来自 SC？——**首版口径**：
      组状态在 SC，leader 需要 floor 时向 SC 查询该分区的"最慢提交偏移"（加法命令或复用 DESCRIBE 的应答）；
      查询失败时**退回 HW**（保守：不删）并记一行告警）
- [ ] `group describe` 的输出包含 `topic[i] committed=… leo=… lag=…`，lag 为推导值
- [ ] 门禁脚本里的第 6 条腿据此断言：慢组之下的段**不被删**；组提交推进后旧的段才可删
