# 23 — 选主与故障转移（SC 提名 + 两段式自我提升）

**What to build:** 集群的可用性路径：SC 通过心跳超时判定 leader 离线 → 从 LRS 中挑**最小滞后**
候选 → 提名；候选**自我提升并回执确认**（两段式）→ SC 更新元数据；旧 leader 回归**自降** follower。

**Blocked by:** 21、22（进度表与复制路径就绪后才能谈选谁）。

**Status:** ✅ done (2026-09-16)

- [x] 提名协议：`CMD_NOMINATE(partition, term-free)` / `CMD_CONFIRM`；**无 epoch/任期字段**
      （结构性不变量，与对标事实一致）
- [x] SC 侧：超时检测（注入式时钟）→ `elect_candidate`（复用 core/replica）→ 提名 →
      确认超时则换下一个候选 → 候选耗尽置 `Offline`（对外可查）
- [x] 候选侧：收到提名才允许提升（非法提名拒绝并报结构化错误）；提升后开始接受 produce
      并作为同步源
- [x] 旧 leader 回归：发现自己不是 leader → 自降 follower → 走 22 的对齐（必要时截断并报告）
- [x] E2E（`scripts/e2e-p3-failover.sh` 的主体）：kill leader → 新 leader 产生 → produce/consume
      继续 → 旧的回归为 follower → 两个副本最终 LEO/HW 一致

## 落地记录

- **两阶段选主（但方向被倒过来了）**：ticket 原定 SC 主动提名（调用候选），实现时发现这会让
  **单线程的两类进程互相阻塞**——SC 提名时候选正在向 SC 问"谁领导"，两边各等对方到自己
  超时（门禁里真实复现了：`nomination failed: handshake: recv: TimedOut`）。
  最终形态：**SC 不主动拨号任何数据节点**。提名是 SC 的一个**状态**（`nominated`），随
  `CMD_LEADER` 应答一起下发；候选读到"自己被提名了"→ 自己提升 → `CMD_CONFIRM` 回报。
  两阶段语义不变（提名与确认是两个动作，缺一不成 leader），但死锁在结构上不可能发生。
  同步给所有控制调用加了 1s 网络超时（`Conn::tcp_with_timeout`）：忙的节点只能让一次调用失败，
  不能挂住别人。
- **候选资格**：`core/replica.elect_candidate`（最小滞后 + LRS 有投票权）。**滞后基准改为
  "存活副本中最靠前的那个"**，而不是消失的 leader 最后报的数——拿一个已经不存在的节点当尺子，
  任何幸存者都会被判"没落后"。
- **提名必须被确认才算数**：`PlacementState::confirm` 校验"这个分区确实被许给过你"，否则拒绝
  （未提请的自我提升被拒）。门禁最后一条断言：所有副本都沉默时 SC 会继续报价，但**没有任何
  选举被记账**，分区保持无 leader（fail-closed，不产生幽灵 leader）。
- **旧 leader 自降**：门禁用 `SIGSTOP`（而非 kill）让 leader 静默——它回来时**仍以为自己是
  leader**，读到 SC 的新答案后自己降级并开始复制。这正是对标系统"旧 leader 回归自降"的场景；
  直接 kill 只能测冷启动，没有"降"可言。
- **离线 leader 不再被视为 leader**：`view()` 只在该地址在线时才报它为 leader（否则报"没人领导"），
  否则客户端会一直拿到一个已死的地址。
- **放置持久化**（顺带为 T24 打底）：`<sc data-dir>/cluster-state.json`；已分配节点即使离线也留在
  副本集合里（副本集合 ≠ 在线节点集合），这正是"HW 在副本死亡时停住"的语义来源。
  与对标系统的差异留痕：节点增减时 moonflux 会**重塑副本集合并自动补数据**（follower 会拉取追平），
  对标系统明确不做存量再平衡——这条差异记入 README 决策（T26）。
- 门禁：`scripts/e2e-p3-failover.sh` 8 条断言全绿（初始 leader → 静默 → 提名+自我提升 →
  新 leader 可读写 → 旧 leader 自降 → 字节级追平 → HW 覆盖两副本 → 无人确认则无 leader）。
- 测试：`apps/cli/node_wbtest.mbt` +4（放置状态、无提名提升被拒、提名不可被他人认领、
  尺子取最靠前副本）。全量：native 144/144、wasm-gc 103/103、18 步门禁全绿。
- 过程中的一次真实事故（留痕）：用 python 的 `str.index` 做区间替换时，锚点串是嵌套匹配的
  子串（`    @client.CMD_LEADER =>` 命中了缩进更深的同名分支），导致整段区域被**复制**
  而不是删除，文件从 1310 行变成 2296 行、两个函数互相污染。教训：程序化编辑必须用**唯一锚点**
  （Edit 工具会拒绝歧义匹配），且改完必须核对行数与编译结果；本次已 `git checkout` 复原后
  用 Edit 重做。
