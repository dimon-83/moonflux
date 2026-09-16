# 22 — follower-pull 复制数据路径 + 受控截断

**What to build:** 真正的字节复制：follower 主动向 leader 拉取（SyncRequest 复用 fetch 语义），
追加到本地日志；leader 依副本回报的 LEO 计算并推进 HW。落地第 20 号 ticket 的语义 ——
真实节点只是账本的驱动者，**不在这里再发明语义**。

**Blocked by:** 20、21。

**Status:** ready-for-agent

- [ ] `core/log` 增受控截断：`truncate_to(offset) -> TruncateReport{dropped_records, dropped_bytes}`
      （区别于恢复期截尾：显式调用、必须报告）；单测覆盖（含截断后 append 的 offset 连续性）
- [ ] 同步命令：`CMD_SYNC_FETCH(topic, partition, from_leo, max_records)` → 批量记录 + leader 的
      `OffsetInfo`；`CMD_SYNC_ACK(leo)`；follower 循环：拉 → 追加 → 回报
- [ ] leader 侧：副本进度表、`compute_high_watermark`、LRS 判定接入（复用 core/replica）
- [ ] follower 侧：落后重连（退避用注入式时钟，不用系统时钟）；启动即对齐（分工处理规则见下）
- [ ] 分歧落地：follower 发现 `local_leo > leader_leo` → `truncate_to(leader_leo)` 并打印丢弃量
- [ ] E2E：两节点复制 —— produce 到 leader，follower 段文件与 leader **前缀字节级一致**；
      杀掉 follower 后 HW 停止推进而 LEO 增长；重启后追平、HW 恢复推进
