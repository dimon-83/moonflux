# 67 — 命令面与节点接线：cluster compact

**What to build:** 一条**显式**压实命令（首期不做周期自动压实）：`moonflux cluster compact
--topic T [--partition N] --remote <node>`，沿 `cluster segments` 的同一条路：新协议命令
`CMD_COMPACT`（显式归类进闭合权限表——**是写不是读**，ReadOnly 拒绝；节点身份不可用），
serve 与 spu 两条 dispatch 挂同一个 `compact_partition`（floor = min(已提交前缀, 消费组地板)，
与 retention 同一口径），打印逐段报告（基线、帧数前/后、删除记录数、字节前/后）。

**实现中的设计修正（2026-09-18，留痕）**：原计划「只认 leader」——但只压 leader 会让 follower
保留已删记录，故障切换后**复活已删的键**。改为**每个持有该分区的节点各自压实自己的副本**，
安全性由 floor 保证而非角色：follower 的 floor 取 **leader 最近一次在同步应答里报告的水位**
（`committed_from_leader`），可滞后 ⇒ 删得更少，永不多删；floor 相同 ⇒ 两边压实出的字节相同
（门禁腿 6 逐段 cmp）。跨洞追赶见 `skip_to`（门禁腿 8）。

**Blocked by:** 66。

**Status:** done (2026-09-18)

- [x] `core/client/protocol.mbt`：`CMD_COMPACT` 常量 + 报告线格式（`WireCompaction`）编解码
- [x] `core/auth`：`CMD_COMPACT` 归入 ReadWrite 类（非 Root/ReadOnly 拒绝；节点命令类不得混入）
- [x] `apps/cli/store.mbt`：`compact_partition(data_dir, topic, partition, floor, now_ms)`（开日志 →
      压实 → 逐段 note 报告 → 关闭；与 `retain_partition` 同形）
- [x] `apps/cli/cluster.mbt`：`cluster compact` 动词 + 用法文本；floor 由节点侧算（心跳里的
      组地板与本地已提交前缀），命令不带 floor 参数
- [x] 跟随者追赶：`replicate_once` 收到「首帧 base > 本地 LEO」的窗口 → `skip_to` 后继续
      （压实只发生在 floor 之下，正常副本不受影响；新副本/落后副本据此跨过空洞）
- [x] `main.mbt` 用法文本 + `apps/cli/metadata_wbtest.mbt` 风格的白盒测试（权限分类、报告格式）
