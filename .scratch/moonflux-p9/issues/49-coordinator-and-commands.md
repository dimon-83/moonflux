# 49 — 协调者与命令面

**What to build:** SC 成为**组协调者**：持有组状态（内存成员 + 持久化的已提交偏移与 epoch），
通过加法命令回答成员；`consume --group` 让 CLI 成为真正的组成员（加入 → 读自己的分区 → 提交 → 优雅离开）。
**分配随心跳应答下发**（与提名、放置同构），成员不需要单独"拿分配"的轮次。

**Blocked by:** 48.

**Status:** done (2026-09-17)

- [x] 协议（加法）：`CMD_GROUP_JOIN = 27`、`CMD_GROUP_HEARTBEAT = 28`、`CMD_GROUP_LEAVE = 29`、
      `CMD_GROUP_COMMIT = 30`、`CMD_GROUP_DESCRIBE = 31`；JOIN/HEARTBEAT 应答 = `epoch + 本成员的分区 + 每分区的提交偏移`
- [x] SC 侧：`GroupRegistry`（`core/group` 的状态 + 已提交偏移的持久化：独立的 `groups.json`，原子写沿用文件存储的 temp+rename）；
      成员存活用**已有的存活超时**（与节点表同一口径）；**变更即换代**，换代在应答里可见
- [x] `consume --group G [--member M]`：加入 → 按分配逐分区读（各分区独立游标）→ 处理（打印）→ **按间隔提交**
      （不是每条记录一次：提交频率是运维量，不是记录量）→ Ctrl-C/退出时 `LEAVE`
- [x] `group list|describe --remote <sc>`：列出组、成员、世代、每分区的提交偏移与滞后（LEO − 已提交）
- [x] 单测（**待补**）：围栏在协调者层的映射（过期 epoch 的 COMMIT → 结构化错误码）、未加入就提交 → 拒绝、重分配时机

### 关账（2026-09-17）

落地：协议 5 个加法命令（27–31）+ `WireGroupMember`/`GroupJoin`/`GroupHeartbeat`/`GroupCommit`/`GroupView`/
`GroupDescription` 编解码 + 新错误码 `ERR_GROUP = 8`（区分"组协议拒绝"与载荷/传输错误）；SC 侧
`apps/cli/groups.mbt`（`GroupRegistry`：内存成员 + 持久化偏移/世代，`groups.json` 原子写、损坏即 fail——静默
重置消费进度不可接受）；控制面 5 个命令臂 + 存活清扫（与节点同一超时，离去只报一次）；CLI
`consume --group G [--member M] [--follow] [--commit-ms N]` 与 `group list|describe`；`cli_pid()`/`cli_sleep_ms()`
两个 shim（成员默认 id 用 pid，避免两个 CLI 共用一个 id 被当成一个成员读两遍）。

**实测**（手动冒烟，2 节点 rf=1）：m1 加入 → 持 2 分区 → 读满 8 条 → 提交（`groups.json` 落盘 offset=4）；
m2 加入 → 持 2 分区 → **续读 0 条**（从已提交偏移开始）→ 幂等提交；join/leave 各自推进世代。

**未做（留给后续票/时间）**：协调者层的单元测试（`GroupRegistry` 的围栏映射、未加入即提交的拒绝）；
`--follow` 的再平衡回收只在冒烟里用过，门禁（T51）会把它钉成腿。诚实标注在 ticket 状态里。

### 补充关账（2026-09-17）

T49 里标注为"待补"的协调者层单测已补齐（`apps/cli/metadata_wbtest.mbt` 3 条：世代围栏、非成员/非持有分区的拒绝、
地板只反映有提交的组）——测试夹具最初共用 `/tmp` 路径，导致前一个用例的提交泄漏进下一个（**由断言当场抓住**），
现在每个用例独立目录。
