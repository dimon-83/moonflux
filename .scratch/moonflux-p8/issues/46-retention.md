# 46 — 滚动与 retention 策略

**What to build:** 滚动阈值（字节/时间）与 retention（字节/时间）两种策略；**retention 只删整段**，
且要求 `段末 offset ≤ floor`——`floor` 由应用计算并传入（= min(该分区已提交前缀 HW, 最慢消费者的已提交
偏移)），内核不猜。时间策略的"现在"由应用传入（内核不读时钟）。删除同时删索引；**每次删除都要报告**
（段 base、字节数、原因），绝不静默。

**Blocked by:** 44, 45.

**Status:** done (2026-09-17)

- [x] `core/log`：`RollPolicy{max_bytes, max_age_ms}`（0 = 关）、`RetentionPolicy{max_bytes, max_age_ms}`；
      `apply_retention(floor, now_ms, policy) -> Result[RetainReport, LogError]`；`RetainReport` 列出被删段
- [x] 不变量：永不删活动段；`floor` 之下才可删；删除后 `read` 的**下界**变成最老段的 base，越界读报
      `OffsetOutOfRange`（不是静默返回空）
- [x] `apps/cli`：把 floor 算出来（分区 HW 与本地消费者已提交偏移的较小者；无消费者时 = HW）并调用；
      `spu`/`serve` 的 housekeeping tick 里按策略触发（带日志）
- [x] 单测：按字节/按时间两种策略的段选择；floor 拦住删除；活动段不可删；越界读的行为

### 关账（2026-09-17）

**两个决定留痕**：① **滚动改为"写入前判断"**（`roll_if_full`）——P8 实测发现"写后再滚"在 `serve`（每请求重开日志）下永远不生效：滚动留下的空尾段被下一次 open 按崩溃语义丢弃，下一批又落回老段。② **索引由存储层提供独立文件**（`SegmentStore.open_index`），因为 `remove(base)` 必须同删两者（孤儿 `.idx` 是等着骗读者的谎）。内核侧新增 `RetentionPolicy` / `RetainReport` / `apply_retention` / `roll_due`；应用侧 `MOONFLUX_RETAIN_BYTES` / `_MS` / `ROLL_MS`（默认全关，删除是运维显式请求）+ `retain_partition`（leader-only、floor=HW、逐段报告）。

**测试**（`core/log_test` 23/23，其中 retention 相关 2 条）：按字节/按时间两种策略的段选择；floor 拦住删除（floor=0 一条不删）；策略关闭时一条不删；活动段永不被删（保留段数 = floor 之上者）；年龄滚动只在活动段有内容时发生；删除后的更老读结构化拒绝、幸存段从 `first_offset` 起仍可读。
