# 46 — 滚动与 retention 策略

**What to build:** 滚动阈值（字节/时间）与 retention（字节/时间）两种策略；**retention 只删整段**，
且要求 `段末 offset ≤ floor`——`floor` 由应用计算并传入（= min(该分区已提交前缀 HW, 最慢消费者的已提交
偏移)），内核不猜。时间策略的"现在"由应用传入（内核不读时钟）。删除同时删索引；**每次删除都要报告**
（段 base、字节数、原因），绝不静默。

**Blocked by:** 44, 45.

**Status:** ready-for-agent

- [ ] `core/log`：`RollPolicy{max_bytes, max_age_ms}`（0 = 关）、`RetentionPolicy{max_bytes, max_age_ms}`；
      `apply_retention(floor, now_ms, policy) -> Result[RetainReport, LogError]`；`RetainReport` 列出被删段
- [ ] 不变量：永不删活动段；`floor` 之下才可删；删除后 `read` 的**下界**变成最老段的 base，越界读报
      `OffsetOutOfRange`（不是静默返回空）
- [ ] `apps/cli`：把 floor 算出来（分区 HW 与本地消费者已提交偏移的较小者；无消费者时 = HW）并调用；
      `spu`/`serve` 的 housekeeping tick 里按策略触发（带日志）
- [ ] 单测：按字节/按时间两种策略的段选择；floor 拦住删除；活动段不可删；越界读的行为
