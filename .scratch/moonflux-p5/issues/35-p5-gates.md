# 35 — P5 关账

**What to build:** 并发门禁汇总 + 文档 / 矩阵 / 决策记录同步。

**Blocked by:** 32、33、34。

**Status:** ready-for-agent

- [ ] `scripts/e2e-p5-concurrency.sh` 纳入 `scripts/gates.sh`
- [ ] README 决策记录（事件循环形态与慢客户端策略；多分区的分区选择规则；算子校验的运行时真相源）
- [ ] 兼容性矩阵：#10 多分区状态更新（存储跟上后由 ⚠️ 转 ✅ 或标注剩余缺口）
- [ ] AGENTS：P5 门禁状态与必要的纪律；tickets 32–35 关闭；全量回归
