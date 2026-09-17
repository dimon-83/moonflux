# 49 — 协调者与命令面

**What to build:** SC 成为**组协调者**：持有组状态（内存成员 + 持久化的已提交偏移与 epoch），
通过加法命令回答成员；`consume --group` 让 CLI 成为真正的组成员（加入 → 读自己的分区 → 提交 → 优雅离开）。
**分配随心跳应答下发**（与提名、放置同构），成员不需要单独"拿分配"的轮次。

**Blocked by:** 48.

**Status:** ready-for-agent

- [ ] 协议（加法）：`CMD_GROUP_JOIN = 27`、`CMD_GROUP_HEARTBEAT = 28`、`CMD_GROUP_LEAVE = 29`、
      `CMD_GROUP_COMMIT = 30`、`CMD_GROUP_DESCRIBE = 31`；JOIN/HEARTBEAT 应答 = `epoch + 本成员的分区 + 每分区的提交偏移`
- [ ] SC 侧：`GroupRegistry`（`core/group` 的状态 + 已提交偏移的持久化：独立的 `groups.json`，原子写沿用文件存储的 temp+rename）；
      成员存活用**已有的存活超时**（与节点表同一口径）；**变更即换代**，换代在应答里可见
- [ ] `consume --group G [--member M]`：加入 → 按分配逐分区读（各分区独立游标）→ 处理（打印）→ **按间隔提交**
      （不是每条记录一次：提交频率是运维量，不是记录量）→ Ctrl-C/退出时 `LEAVE`
- [ ] `group list|describe --remote <sc>`：列出组、成员、世代、每分区的提交偏移与滞后（LEO − 已提交）
- [ ] 单测：围栏在协调者层的映射（过期 epoch 的 COMMIT → 结构化错误码）、未加入就提交 → 拒绝、重分配时机
