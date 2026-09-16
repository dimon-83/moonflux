# 22 — follower-pull 复制数据路径 + 受控截断

**What to build:** 真正的字节复制：follower 主动向 leader 拉取（SyncRequest 复用 fetch 语义），
追加到本地日志；leader 依副本回报的 LEO 计算并推进 HW。落地第 20 号 ticket 的语义 ——
真实节点只是账本的驱动者，**不在这里再发明语义**。

**Blocked by:** 20、21。

**Status:** ✅ done (2026-09-16)

- [x] `core/log` 增受控截断：`truncate_to(offset) -> TruncateReport{dropped_records, dropped_bytes}`
      （区别于恢复期截尾：显式调用、必须报告）；单测覆盖（含截断后 append 的 offset 连续性）
- [x] 同步命令：`CMD_SYNC_FETCH(topic, partition, from_leo, max_records)` → 批量记录 + leader 的
      `OffsetInfo`；`CMD_SYNC_ACK(leo)`；follower 循环：拉 → 追加 → 回报
- [x] leader 侧：副本进度表、`compute_high_watermark`、LRS 判定接入（复用 core/replica）
- [x] follower 侧：落后重连（退避用注入式时钟，不用系统时钟）；启动即对齐（分工处理规则见下）
- [x] 分歧落地：follower 发现 `local_leo > leader_leo` → `truncate_to(leader_leo)` 并打印丢弃量
- [x] E2E：两节点复制 —— produce 到 leader，follower 段文件与 leader **前缀字节级一致**；
      杀掉 follower 后 HW 停止推进而 LEO 增长；重启后追平、HW 恢复推进

## 落地记录

- **内核原语**（`core/log`）：`read_raw`（整帧原样读，`from` 必须落在帧边界，否则拒绝）、
  `append_raw`（原样追加预编码帧，校验帧 offset 与本日志 `next_offset` **连续**——空洞或重叠
  一律拒绝）、`truncate_to`（受控截断，返回 `TruncateReport{dropped_records, dropped_bytes}`）。
  为什么原样搬运：重编码会让两个节点用不同的**分帧**存同样的记录，"副本是 leader 的字节前缀"
  这条门禁断言就会失效。
- **协议**（apps/client）：`CMD_LEADER=10` / `CMD_SYNC_FETCH=11` / `CMD_SYNC_ACK=12` /
  `CMD_OFFSET_INFO=13`；载荷 = `PartitionRef` / `SyncRequest` / `SyncResponse`（含 HW/LEO +
  原始帧字节）/ `SyncAck`（**携带发送者地址**，否则 leader 无法把 ACK 归属到某个副本——
  `ProgressLedger::observe` 拒绝陌生副本）/ `PartitionView`（leader + 副本集合）。
- **控制面放置**：SC 每 tick 读 `<data-dir>/topics.json`（声明式 topics）+ 在线 SPU 节点表
  → `core/cluster.reconcile` → `apply_actions` → 对外回答 `CMD_LEADER`。调和是 T19 的纯函数，
  这里只有接线；改文件即生效（level-triggered），无事件。
- **数据面**：leader 侧持有 `core/replica.ProgressLedger`（HW = min(LEO)），服务
  SYNC_FETCH/SYNC_ACK/OFFSET_INFO；follower 侧每 tick 先问 leader 的 LEO，再决定截断或拉取。
- **分歧处理落地**：`local_leo > leader_leo` → `truncate_to(leader_leo)` 并打印丢弃量；
  门禁脚本会在副本目录里"伪造"一段未复制的尾巴来触发它。
- **两个真实的坑**：
  1. **leader 不把自己的 LEO 折进账本** ⇒ 对外报 "leo 0" 而日志里有数据，follower 于是认为
     无事可做。修法：`sync_leader_leo()` 在每次应答前从自己的日志读回 LEO（leader 的 LEO 是
     关于它自己日志的事实，不是谁报告给它的）。
  2. **follower 先按 `from=my_leo` 请求字节**：当自己的 LEO 超过 leader 时，leader 无法回答
     （读越界）⇒ 永远学不到 leader 的 LEO，永远不会截断。修法：先问 `CMD_OFFSET_INFO`
     （与位置无关），再决定截断/拉取。这也是"先问权威"的顺序纪律。
- 门禁：`scripts/e2e-p3-replication.sh` 7 条断言全绿（放置→字节前缀复制→HW 待确认→
  follower 停机 HW 停滞而 LEO 增长→重启追平字节一致→分歧尾巴截断并报告），已纳入 `gates.sh`。
- 测试：`core/log_test` +4（原样读/原样写/截断/拒绝非法边界）、`apps/client` +2（同步载荷与
  视图编解码）。全量：native 140/140、wasm-gc 103/103、17 步门禁全绿。
- 未做（属 T24/T26）：客户端可见的 OffsetInfo 随 FETCH 返回（矩阵 #11 的读钳制开关）、
  `topic create` 作为控制面动词（当前是 topics.json 文件）。
