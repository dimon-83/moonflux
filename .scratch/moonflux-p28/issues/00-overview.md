# P28：存储维护调度——后台压实加入既有维护节拍（overview）

**定位**：兼容性矩阵的诚实缺口收口——「compaction exists but is operator-triggered (no periodic/background cleaner)」。

**现状盘点（立项时实测，修正立项选项里的描述）**：retention **已经是周期性的**——serve 的 housekeeping 循环每 1s 跑 `serve_retain_all`（声明∪磁盘，P9 起），spu 的 leader tick 逐分区跑 `retain_partition`（P8/T46）。真正缺席的只有**压实**：`cluster compact`（集群/单机）是操作员命令，没有任何自动路径。

**设计**：

- **节拍即开关**：`MOONFLUX_COMPACT_MS`（默认 0 = 关）——重写数据永远不是默认（与「删除不是默认」同源）；设为正数即启用，值就是两次后台压实尝试的最小间隔。
- **重写门槛**：`MOONFLUX_COMPACT_MIN_DIRTY_BYTES`（默认 0 = 有可弃即重写）——透传内核既有的 `CompactionPolicy.min_dirty_bytes`（P8 时代就有的杠杆），不是第二套语义。
- **floor 单一真相**：后台压实用与 retention 相同的 floor——serve 走 `serve_partition_floor`（自身末端降到了最慢组），spu 走 `partition_floor`（已提交前缀 ∩ 组地板）；手动命令不变（阈值仍为 0）。
- **节拍状态**：serve 在 housekeeping 状态旁加 `last_compact`（全局枚举，一个时间戳够）；spu 的 tick 是 50ms——远热于封存段扫描——所以在 HostTable 上按 `topic/partition` 记每分区上次尝试时间，与 tick 解耦。
- **不变量全部继承**：只动 `段末 ≤ floor` 的封存段、永不动活动段、逐段报告、句柄走 P16 缓存、kernel 不读时钟（`now_ms` 由宿主传入）、幂等是构造性质（无可弃 = 空报告 = 零写）。

**Tickets**：100 策略与调度（serve + spu）· 101 门禁 · 102 文档关账。编号全局连续（承 99）。
