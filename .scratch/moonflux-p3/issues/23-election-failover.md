# 23 — 选主与故障转移（SC 提名 + 两段式自我提升）

**What to build:** 集群的可用性路径：SC 通过心跳超时判定 leader 离线 → 从 LRS 中挑**最小滞后**
候选 → 提名；候选**自我提升并回执确认**（两段式）→ SC 更新元数据；旧 leader 回归**自降** follower。

**Blocked by:** 21、22（进度表与复制路径就绪后才能谈选谁）。

**Status:** ready-for-agent

- [ ] 提名协议：`CMD_NOMINATE(partition, term-free)` / `CMD_CONFIRM`；**无 epoch/任期字段**
      （结构性不变量，与对标事实一致）
- [ ] SC 侧：超时检测（注入式时钟）→ `elect_candidate`（复用 core/replica）→ 提名 →
      确认超时则换下一个候选 → 候选耗尽置 `Offline`（对外可查）
- [ ] 候选侧：收到提名才允许提升（非法提名拒绝并报结构化错误）；提升后开始接受 produce
      并作为同步源
- [ ] 旧 leader 回归：发现自己不是 leader → 自降 follower → 走 22 的对齐（必要时截断并报告）
- [ ] E2E（`scripts/e2e-p3-failover.sh` 的主体）：kill leader → 新 leader 产生 → produce/consume
      继续 → 旧的回归为 follower → 两个副本最终 LEO/HW 一致
