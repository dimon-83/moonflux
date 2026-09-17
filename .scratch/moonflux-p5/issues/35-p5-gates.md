# 35 — P5 关账

**What to build:** 并发门禁汇总 + 文档 / 矩阵 / 决策记录同步。

**Blocked by:** 32、33、34。

**Status:** ✅ done (2026-09-17)

- [x] `scripts/e2e-p5-concurrency.sh` 纳入 `scripts/gates.sh`
- [x] README 决策记录（事件循环形态与慢客户端策略；多分区的分区选择规则；算子校验的运行时真相源）
- [x] 兼容性矩阵：#10 多分区状态更新（存储跟上后由 ⚠️ 转 ✅ 或标注剩余缺口）
- [x] AGENTS：P5 门禁状态与必要的纪律；tickets 32–35 关闭；全量回归

## 落地记录

- `scripts/e2e-p5-concurrency.sh`（6 腿）与 `scripts/e2e-p5-partitions.sh`（5 腿）、
  `scripts/e2e-p5-operator.sh`（4 腿）全部纳入 `scripts/gates.sh`（**24 步全绿**）。
- README 决策 27（事件循环与慢客户端策略）、28（分区选择规则：显式分区 + 缺省 0，键哈希留待后续；
  **非 0 分区复制未做**的诚实标注）、29（算子校验以运行时为真相源）。
- 矩阵 #10 更新（多分区存储与数据路径落地、索引/retention 与跨分区复制仍在）。
- AGENTS：P5 行 + §3 目录（operator 命令面）。
- tickets 32–35 关闭；全量回归 24/24；native 159/159、wasm-gc 115/115。
