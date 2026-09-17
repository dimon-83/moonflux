# 00 — P7 里程碑概览（多分区复制收口）

**门禁（可证伪）**：一个 3 分区、RF=2 的主题分布在 2 个数据节点上——每个分区**各自**有 leader/replicas/HW；
杀掉一个副本只让**它持有的那个分区**的高水位停滞，其它分区继续推进；一个分区换主不打扰另一个；
分歧回归按分区分头截断并报告；`cluster offsets --partition N` 与 `cluster status` 显示每分区真相。

**为什么是这一票**：`docs/compatibility-matrix.md` #10 与 T33 的缺口写在明处——复制的**语义**（follower-pull、
HW=min(LEO)、无 epoch、截断报告）已经成立，但它只覆盖分区 0；非 0 分区退化为"单节点日志，HW==LEO"。
控制面（`core/cluster` 的放置/选主、`CMD_LEADER`/`CMD_CONFIRM` 的 `PartitionRef`）早已是分区级的，
数据节点是唯一还按单分区写的部件。

**范围**：数据节点多分区宿主 + 每分区水位上报与按分区选主 + 多分区数据面/运维面 + 门禁与留痕。
**不做**：跨分区事务/原子多分区写、分区再平衡（存量迁移）、消费者组、段索引/retention（另立票）。

**Tickets（编号全局连续）**
- 40 数据节点多分区宿主（宿主表 + 控制面分配随心跳应答下发 + 按 (topic,partition) 路由）
- 41 每分区水位上报与按分区选主（node record 加法段 + 选主 yardstick 读该分区 LEO）
- 42 多分区数据面与运维面（leader-only 生产、按分区 HW、`cluster status`/`offsets` 每分区真相）
- 43 门禁 + 矩阵 #10 收口（`scripts/e2e-p7-partitions.sh` + README 决策 29 + AGENTS §2）

**状态（2026-09-17 全部关账）**
- [x] 40 数据节点多分区宿主（宿主表 + 放置随心跳下发 + 按 (topic,partition) 路由 + spu 换 ConnectionHub）
- [x] 41 每分区水位上报与按分区选主（节点记录加法段 + leo_of + `cluster leader --partition` 修复）
- [x] 42 多分区数据面与运维面（leader-only 写入 + 按分区 HW + `cluster status` 显示副本地址 + 帧边界截断）
- [x] 43 门禁与留痕（`scripts/e2e-p7-partitions.sh` 7 腿；矩阵 #10 ✅；README 决策 29/30；AGENTS §2）
