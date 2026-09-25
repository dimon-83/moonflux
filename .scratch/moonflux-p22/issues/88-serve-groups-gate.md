# 88 — serve 消费组门禁与文档

**What to build:** `scripts/e2e-p22-serve-groups.sh`（对端 = 单个 serve，不是 sc+spu 集群）；
全部文档同步。

**Blocked by:** 87。

**Status:** done (2026-09-25)

- [x] 腿 1：produce 自动建题（2 分区）→ 两成员 join → 份额覆盖全部分区且不重叠
- [x] 腿 2：投递无缺口无交叠（成员各读各的份额）
- [x] 腿 3：成员被杀 → sweep（~3s）→ 幸存者接管，续读无缺口
- [x] 腿 4：过期世代提交被拒（describe 取 epoch → 制造换代 → 旧 epoch commit 被拒）
- [x] 腿 5：偏移跨 serve 重启存活（groups.json；新成员从 committed 续读）
- [x] 腿 6：慢消费者挡住 retention（MOONFLUX_ROLL_BYTES/RETAIN_BYTES，组地板之下的段
      不删、之上的按策略删；floor = min(自身末端, 组地板)）
- [x] `scripts/gates.sh` 加步（38 → 39）
- [x] 文档：AGENTS §2 P22 行 + P9 纪律块补 serve 宿主一句；README 决策 46；
      feature-matrix 消费组行；compatibility-matrix #11 证据补 serve 路径；
      user-guide 消费组节补"单机 serve 也可用"；roadmap 里程碑；看板四道
