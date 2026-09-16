# 33 — 多分区存储与按分区读写

**What to build:** 把每个主题单分区（`partition-0.log`）扩展到 `partition-N.log`；生产/消费可以指定
分区（缺省由键哈希或轮转决定），放置与 leader 分配沿用 P3 的控制面模型（`PartitionId{topic,index}`）。

**Blocked by:** 32（并发连接先立住，否则多分区会让"一个连接卡住全服"的问题放大）。

**Status:** ready-for-agent

- [ ] 存储：`open_topic_log(data_dir, topic, partition)`；目录布局与恢复语义保持不变（段文件即协议流）
- [ ] 服务端：PRODUCE/FETCH 载荷携带分区号；缺省分区选择规则显式定义并留痕（默认分区 0，
      键哈希作为后续；**不得**引入 Kafka 的隐式分区语义）
- [ ] CLI：`produce/consume --partition N`；`topic create --partitions N` 之后真的生成 N 个分区
- [ ] 控制面：放置与副本按分区独立（`core/cluster` 已支持），leader/HW/LEO 查询按分区
- [ ] 门禁：多分区 e2e（每分区独立写入与读取、互不串扰；分区级水位独立推进）
