# 100 — 策略与调度：后台压实（serve + spu）

**What to build**：

- `apps/cli/store.mbt`：`compact_interval_ms()`（`MOONFLUX_COMPACT_MS`，默认 0 = 关）与 `compaction_min_dirty_bytes()`（`MOONFLUX_COMPACT_MIN_DIRTY_BYTES`，默认 0）；解析抽成纯函数（Option[String] 进，坏值归 0）供 wbtest；`maintenance_due(last, now, interval)` 纯函数钉住判定。
- `compact_partition` 增加 `policy` 参数：手动两处（node 的 CMD_COMPACT、serve 的命令臂）传零阈值（行为不变）；后台路径传 `min_dirty_bytes` 旋钮值。
- serve：housekeeping 块旁加 `last_compact`，到期跑 `serve_compact_all`（枚举与 `serve_retain_all` 同源：声明∪磁盘，floor 走 `serve_partition_floor`）。
- spu：`HostTable` 加 `mut compaction_due : Map[String, Int64]`（key = `topic/partition`，缺 = 立即到期），`tick_one` 的 leader 臂在 retention 之后按到期跑 `compact_partition`。

**不变量**：默认关；floor 单一真相；报告逐段不静默；句柄走缓存；kernel 时钟仍由宿主传入。

**Blocked by**：无。

**Status**：done（2026-10-06）

- [x] 纯函数解析 + due 判定 + wbtest
- [x] compact_partition 参数化（手动语义不变）
- [x] serve 周期压实（serve_compact_all + last_compact）
- [x] spu 逐分区节拍（HostTable map + tick_one leader 臂）


**落地实录**：wbtest 3 条（解析/门槛/due 数学）；`compact_partition` 增加 policy 参数，手动两处传零阈值不变。一个字段教训：Map 字段本身不被重赋值时声明 `mut` 会吃 `unused_mut` 错误（deny 级）——改的是 Map 对象，不是绑定。
