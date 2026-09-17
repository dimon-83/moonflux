# 42 — 多分区数据面与运维面

**What to build:** 生产/消费在多分区上遵守与分区 0 相同的语义：**只有 leader 接受生产**，`fetch` 默认读
未提交（≤ LEO），committed 读 ≤ HW；非 leader 的生产得到结构化 `ERR_WRONG_ROLE`（附当前 leader）。
运维面把每分区的真相显示出来，让"哪个分区还在动、哪个停住了"一眼可见。

**Blocked by:** 40, 41.

**Status:** done (2026-09-17)

- [x] `dispatch_produce_partition`：先按宿主判角色（非 leader → 拒绝并给出 leader 地址），再追加并 `sync_leader_leo`
- [x] `dispatch_fetch_partition`：默认 ≤ LEO；`CMD_FETCH_COMMITTED` 在分区上按该分区宿主账本的 HW 钳制
- [x] `apps/cli/cluster.mbt`：`cluster status` 逐分区列出 `topic[i] leader replicas hw leo`（单分区输出保持兼容）
- [x] 消费路径（`consume --partition N`）在多分区上照常工作（回归）
- [x] 单测：非 leader 生产被拒；HW 钳制按分区

### 关账（2026-09-17）

落地：`require_leader`（非 leader 的结构化拒绝，附 leader 地址）+ 生产/committed 读的按分区路由与 HW 钳制、
`CMD_OFFSET_INFO` 要求具名主题（水位是逐分区的，没有"那个"水位）、`cluster status` 逐分区列出
`topic[i] leader=… replicas=<地址列表> hw=… leo=…`（P7 起显示地址而非数量，运维需要知道去哪台机器找）。

**顺带修复**：`node.mbt` 三处 HELLO 把帧版本号当协议主版本发出（`serve` 校验后暴露）；`core/log.truncate_to_boundary`
（帧内截断退到前一帧边界 + 重新拉取）。
