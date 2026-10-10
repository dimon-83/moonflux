# T109 · HTTP 源的可选轮询（`interval_ms`）

**What to build**: `{"type":"http","url":…,"interval_ms":N}`。0/缺省 = 原一次性 GET（P1 行为逐字节不变）；正数 = 轮询：`Quiet` 直到间隔到期，然后重取。负数/非数值按名拒绝。

**Why the contract matters more than the feature**: 三态 pull 里 `Quiet` = "此刻没有"、`Exhausted` = "永远没有"。轮询器若在第一批之后说 `Exhausted`，`pipeline run` 就会认定源结束——"轮询"退回成"一次性"。

**Blocked by**: 无。

**Status**: ✅ 2026-10-10（决策 57）

**Checklist**:
- [x] `HttpSource(String)` → `HttpSource(String, Int64)`；spec 解析接受 `interval_ms` 并拒绝负数/非数值（`core/spec` 四态测试 13/13）
- [x] `apps/connectors.http_source(url, timestamp, interval_ms)`：轮询期 `Quiet`、到点重取、每批按取数时刻打戳
- [x] 拓扑命名区分 `http poller: … every Nms` 与 `http source: …`
- [x] 案例 09 增 `spec-poll.json` + README 轮询小节（含"重复投递、去重是读者的事"）
- [x] 门禁腿 `scripts/e2e-p30-connector-examples.sh` 第 7 条（两次 200ms 轮询 → ≥4 条过滤记录、进程存活、主题 ≥8 条两批）
- [x] user-guide 源类型表 / feature-matrix / 缺口方案 §2 缺口 9 / 决策 57 / roadmap / board
