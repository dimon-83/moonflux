# 26 — P3 关账：文档 / 决策记录 / 矩阵状态 / 全量回归

**What to build:** P3 的证据汇总与文档同步。

**Blocked by:** 25.

**Status:** ready-for-agent

- [ ] README 决策记录：follower-pull 语义、HW=min(LEO)、LRS 判定、无 epoch 不变量、
      **分歧处理（本项目显式定义）**、**并发写的 P3 答案（单 leader）**、元数据存储可插拔
- [ ] 兼容性矩阵：#8 提交原子性（多写者 → 单 leader 语义）、#10 多分区（若落地）、
      #11 读钳制开关（Committed/Uncommitted）状态更新，附证据入口
- [ ] AGENTS：P3 门禁状态；必要的执行纪律（如有）
- [ ] `docs/compatibility-matrix.md` 与 README 路线图的 P3 行标记达成 + 证据
- [ ] tickets 19–26 关闭；`scripts/gates.sh` 全绿（含 P3 门禁）
