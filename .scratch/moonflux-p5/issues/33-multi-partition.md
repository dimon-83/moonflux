# 33 — 多分区存储与按分区读写

**What to build:** 把每个主题单分区（`partition-0.log`）扩展到 `partition-N.log`；生产/消费可以指定
分区（缺省由键哈希或轮转决定），放置与 leader 分配沿用 P3 的控制面模型（`PartitionId{topic,index}`）。

**Blocked by:** 32（并发连接先立住，否则多分区会让"一个连接卡住全服"的问题放大）。

**Status:** ◐ partial (2026-09-17) — 存储与数据路径、CLI、控制面查询已落地；跨分区复制（非 0 分区）未做

- [x] 存储：`open_partition_log(data_dir, topic, partition)`；目录布局与恢复语义保持不变（段文件即协议流）
- [x] 协议：`CMD_PRODUCE_PARTITION=20` / `CMD_FETCH_PARTITION=21`（**加法式**——既有 PRODUCE/FETCH
      的载荷与语义不变、恒指分区 0，沿用 T27 的规则：帧版本号只拦不兼容变更）`open_topic_log(data_dir, topic, partition)`；目录布局与恢复语义保持不变（段文件即协议流）
- [x] 服务端：PRODUCE/FETCH 载荷携带分区号；缺省分区选择规则显式定义并留痕（默认分区 0，
      键哈希作为后续；**不得**引入 Kafka 的隐式分区语义）
- [x] CLI：`produce/consume --partition N`；`topic create --partitions N` 之后真的生成 N 个分区
- [x] 控制面：放置与副本按分区独立（`core/cluster` 已支持），leader/HW/LEO 查询按分区
- [x] 门禁：多分区 e2e（每分区独立写入与读取、互不串扰；分区级水位独立推进）

## 落地记录

- **存储**：`open_partition_log(data_dir, topic, partition)`（`topic_log_path` 按分区）；恢复语义
  与单分区完全一致（撕裂尾截断到确认前缀）。分区 0 的旧路径 `open_topic_log` 保持原签名。
- **协议（加法式）**：`CMD_PRODUCE_PARTITION=20` / `CMD_FETCH_PARTITION=21`，载荷 = uleb topic +
  uleb partition + （批帧 / be64+u32）。**既有命令的字节与语义不变**——所有 P4 前的客户端与
  golden 脚本零改动；`max` 用 u32 BE 与 FETCH 完全一致（第一版写成 varint 就是"MalformedLength"）。
- **数据路径**：单节点 `serve` 与数据节点 `spu` 的分发都接了新命令（同一份
  `dispatch_produce_partition` / `dispatch_fetch_partition`，无第二实现）；分区是独立的日志，
  **水位按分区独立推进**（单副本分区的 HW == LEO，即"写入即已提交"的 P3 语义）。
- **CLI**：`produce --partition N`、`consume --partition N`、`cluster offsets --partition N`；
  `cluster offsets` 的请求**带分区号**，但空载荷仍合法（= 分区 0，P4 前客户端的形状不变）。
- **控制面**：`topic create --partitions N` 声明 N 个分区，调和逐分区放置（`PartitionId` 早已
  分区化，本次只是让它真实生效）。
- **门禁**：`scripts/e2e-p5-partitions.sh` 5 条断言全绿（逐分区放置 → 各自的段文件 → 读写互不
  串扰 → 水位独立推进 → 缺省分区 0 兼容）。
- **如实标注的缺口（本 ticket 保持 ◐）**：**复制目前只覆盖分区 0** —— 非零分区是单节点日志
  （在其所属节点上 HW == LEO）。`PartitionRef` 已在所有线类型里分区化（T22 的设计预留生效），
  剩余工作是 SPU 侧的每分区 host 表与心跳的每分区 LEO 上报；在完成之前，
  **rf>1 的多分区主题不会被如实复制**，控制面对这类声明仍按放置记录（诚实显示），但数据只在
  leader 上。此项与"心跳载荷分区化"一起列为下一 ticket 的内容。
