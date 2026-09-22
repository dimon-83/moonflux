# 75 — P17 基准抓到的既有缺陷：accept 阻塞在 poll 之前

**What to build:** 修掉 `ConnectionHub::poll_once` 的轮次形状缺陷：accept 先于连接 poll，且 accept
本身带整 tick 的阻塞期限——一个恰好在服务端 flush 之后发出下一请求的对端（一切请求-应答客户端
都是这个形状）**每个请求都确定性等满一个 tick**。

**定位过程（P17 基准的第一份产出）**：
- `benchmark produce --remote` 每批 ack 稳定 ~205 ms（40 批 min 203/max 209，离散仅 ~6 ms），
  与载荷大小无关（8 字节记录的 `latency` 模式 ack 仍 ~202 ms）；e2e 恰好 = 2 × 202 ms。
- 本地同路径 1.7 ms/批 → 200 ms 全在传输往返；单条既有 `produce --remote` 墙钟 0.40 s。
- **不是 Nagle**：请求与应答都是单次整帧写。是 `serve.mbt` 的 `HUB_TICK_MS = 200`——`poll_once`
  每轮先在 `accept()` 里阻塞至多 200 ms（等新连接），才 poll 既有连接；flush 后 ε 时刻到达的
  下一请求坐穿整个 accept 窗口。
- 对既有叙事的修正：P16 报告的「12 MiB 复制 1 秒收敛」与 P15 的「20 MiB 远程生产 2.0 s」里
  相当一部分是本条 tick 税，不是数据搬运的时间。P13 门禁没抓到它，因为门禁断言的是「不阻塞/
  不误判」，从不量延迟——这正是 benchmark 立项的理由（roadmap「P16 后续 ①」）。

**修法**：listener 与全部连接进**同一个 poll 集**（一次 poll 等所有事）；accept 仅在 poll 报告
listener 就绪时调用（在未就绪的 listener 上 accept 就是刚逃掉的阻塞）；每次 accept 前用零超时
poll 复核，避免 drain 循环在排空后又阻塞。`adapters/net-native` 补 `TcpListener::raw_fd`。

**Blocked by:** 73（基准是它的探针）。

**Status:** done (2026-09-22)

- [x] `poll_once` 重构：poll 集 = [listener] ++ conns（`TcpListener::raw_fd` 进
      `adapters/net-native`）；就绪索引 0 = listener；空连接特判删除（listener 恒在集内，
      不再有 `poll_fds` 空表即返的忙碌自旋）
- [x] `drain_accepts`：每次 accept 前零超时 poll 复核就绪——期限仍挂在 listener 上，
      但永远不会在未就绪时被调用
- [x] 验证：produce ack p50 **205 ms → 3.97 ms**（51×），吞吐 2,372 → **116,271 recs/s**
      （29.8 MB/s）；latency 模式 produce-ack p50 **202 ms → 107 µs**、e2e p50
      **404 ms → 189 µs**（2000×）；`opened` 计数不变（P16 语义无恙）
- [x] 三个服务端（serve / spu / sc）同享此修复（都在 ConnectionHub 上）
- [x] 提速浮出并修掉两条**门禁自身的时序竞态**（产品语义按设计正确，两侧各跑 2–3 遍稳定绿）：
      ① p8「幸存窗口」腿——旧循环首回合睡穿 accept 块（~400 ms），首个 retention 扫描必然
      落在 z 追加之后；新循环在连接到达即醒，**启动期** housekeeping 扫描抢在追加之前跑
      （210 B 预算 150 → 只删 @0），门禁 grep 到启动扫描的日志行就过早读窗。修法：重试条件从
      「consume 失败」改为「窗口落到 z 开头」。② p14 腿 6——follower 压实 floor =
      leader 最近一次 sync 应答报告的水位，可滞后一轮（P14 纪律原文）；旧时序下
      `wait_for_hw`（问 leader）返回时 follower 视图大概率已跟上，新时序下必然差一轮 →
      follower 少删一条 → 永不收敛。没有命令能读 follower 的 committed 视图
      （`CMD_OFFSET_INFO` 问 follower 答 `(0, 自身 LEO)`——账本在 leader），修法：重发
      `cluster compact`（幂等）直到收敛（幸存者集合由 floor 唯一决定）
