# 43 — 门禁 + 矩阵 #10 收口

**What to build:** 一条可复现的多分区复制门禁：3 分区 RF=2 分布在 2 个 spu 上，逐条钉住分区级语义，
并把 compatibility-matrix #10 从 ⚠️ 推到 ✅（附证据入口）。

**Blocked by:** 40, 41, 42.

**Status:** done (2026-09-17)

- [x] `scripts/e2e-p7-partitions.sh`（≥6 腿）：① 放置：3 个分区在 2 节点上各有 leader/replicas
      ② 每分区复制：向每个分区生产 → follower 追平 → 各分区 HW == LEO
      ③ **分区隔离**：杀掉一个副本节点 → 它持有的分区 HW 停滞、其它分区继续推进（同节点其它分区不受影响）
      ④ 按分区选主：某分区 leader 死亡 → 该分区换主且确认，其它分区 leader 不变
      ⑤ 分歧回归：旧 leader 带脏尾巴回归 → 按该分区 leader LEO 截断并报告丢弃量
      ⑥ 运维面：`cluster status`/`cluster offsets --partition N` 每分区水位与门禁观测一致
- [x] 纳入 `scripts/gates.sh`（第 26 步）
- [x] `docs/compatibility-matrix.md` #10 状态迁移 + 证据入口；T33 的"非 0 分区单节点"注记更新
- [x] README 决策 29（多分区复制的语义与取舍）、路线图 P7 行；AGENTS §2 阶段表 P7 行 + P7 纪律块

### 关账（2026-09-17）

`scripts/e2e-p7-partitions.sh`（**7 条腿**，已注册进 `gates.sh` 第 26 步）：① 逐分区 leader 且**分散** ② 三节点
各自采纳分配 ③ 三分区各自复制到 `hw==leo==2` ④ 静默→选举：控制面替掉死者持有的 leader ⑤ **分区隔离**：
死者所在的 2 个分区水位停滞（1 个停在确认前缀、1 个停在新 leader 末端之下）、不在其副本集合里的分区继续
推进到 `hw==leo==3` ⑥ 换主只发生在其持有的分区，邻居 leader 不动 ⑦ 分歧回归按分区截断并报告 ⑧ 运维面逐分区真相。

矩阵 #10 → ✅；README 路线图 P7 行 + 决策 29/30；AGENTS §2 阶段表 P7 行 + P7 多分区纪律块。
全量 `scripts/gates.sh`：**26 步全绿**（native 186、wasm-gc 137）。
