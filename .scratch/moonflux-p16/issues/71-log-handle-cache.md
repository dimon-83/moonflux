# 71 — P16 进程级有界日志缓存

**What to build:** `apps/cli/logcache.mbt`：进程级缓存（LRU，`MOONFLUX_LOG_CACHE` 默认 128，≤ 0 即
关闭）；`store.mbt` 的 `open_partition_log` 命中即复用（原实现改名 `open_partition_log_uncached`，
恢复语义不变）；每次真实打开往 **stderr** 记一行 `opened topic[p] (log end N, M segment(s))`——既是
运维可见性也是门禁的结构计数器。两条不变量让缓存安全：**缓存是唯一持有者**（无调用点跨调用持有句柄，
所以淘汰只是策略而非正确性 bug）；**一个进程一个写入者**（append / roll / truncate / skip_to /
压实 / 保留全经同一句柄，句柄自维护 `segments` / `next_offset`，故无需失效）。

**Blocked by:** 无（P15 的复制窗口让 12 MiB 复制成为可复现的触发器——是动机，不是依赖）。

**Status:** done (2026-09-19)

- [x] `logcache.mbt`：`LogCache`（get/put，`last_used` 用单调计数而非时钟——与内核确定性红线同源）
      + 上限与 LRU 淘汰；`data_dir` 进键（测试进程可能开多个数据目录）
- [x] `store.mbt`：`open_partition_log` 包装缓存；所有日志打开路径都从它拿（不新增绕过缓存的打开）
- [x] `opened` 行走 stderr（stdout 是数据流：`consume | cut -f4` 是常态，诊断混进记录流无法区分）
- [x] 门禁腿：13 请求跨 6 段只开一次；`MOONFLUX_LOG_CACHE=0` 时 opened 随请求数增长（计数有效）；
      单条缓存（上限 1）淘汰后重开不丢记录
- [x] 效果实测：12 MiB 复制从「永远 `deadline`、`hw` 停在 0」→ **1 秒收敛**；20 MiB 远程生产
      9.5s → 2.0s
