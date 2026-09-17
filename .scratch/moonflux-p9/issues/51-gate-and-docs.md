# 51 — 门禁 + 留痕

**What to build:** `scripts/e2e-p9-groups.sh`（≥6 腿）：① 两成员加入 4 分区主题 → 每分区恰好一个属主
② 杀掉一个成员 → 存活者接管并**从提交偏移续读** ③ 总消费数守恒（不丢；重复允许——至少一次）
④ 过期 epoch 提交被拒 ⑤ 提交跨 SC 重启存活 ⑥ 慢消费者拖住 retention（其下数据不被删）
⑦ `group describe` 的滞后与观测一致。

**Blocked by:** 48, 49, 50.

**Status:** ready-for-agent

- [ ] 纳入 `scripts/gates.sh`；矩阵 #11 消费组一栏 ⏳ → ✅（附证据入口）
- [ ] README 路线图 P9 行 + 决策 32（消费组语义：至少一次、epoch 围栏、分配随心跳下发、floor 合流）
- [ ] AGENTS §2 P9 行 + 消费组纪律块
