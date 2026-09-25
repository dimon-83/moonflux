# 87 — serve 模式消费组协调

**What to build:** `serve`（单机全一）自己当协调者：GroupRegistry 布线进 serve 会话、五条
group 命令真实分发（替换 P18 的解释性拒绝）、成员静默清扫、分区枚举 = 声明 ∪ 磁盘
（serve 的 produce 自动建题不落声明，枚举漏掉它们就是撒谎——P18 列表同一原则）、
compact 与 retention 的地板接最慢消费者（P9 的"下界"在单机同样成立）。

**Blocked by:** 无。

**Status:** done (2026-09-25)

- [x] `group_partitions` 取 max(声明数, 磁盘 partition-N 目录数)；SC 数据目录无
      `topics/` → 磁盘项自然为 0，同一实现对两种宿主都诚实
- [x] `cmd_serve` 持有 `GroupRegistry::new(data_dir, NODE_TIMEOUT_MS)`，传入
      `dispatch_session_frame`；五个 CMD_GROUP_* 臂与 SC 侧逐字同构
      （join/heartbeat/leave/commit/describe；describe 空名 = JSON 列表）
- [x] housekeeping（1s）里 sweep 静默成员，逐个 note（与 SC 同一句话术）
- [x] `CMD_COMPACT`（serve）地板 = min(自身水位, group floor)；retention（applied
      主题 p0）同样取交集——`floors()` 只认声明过该主题且**真提交过**的组（P9 口径）
- [x] 删除 `group_coordination_refusal`；e2e-p0 的 group 腿翻转为"describe 可用"
- [x] wbtest：磁盘 ∪ 声明枚举（自动建题计入份额、声明优先数、无目录 = 0）
- [x] 权限表**一次显式重归类**（group 命令已归类：成员命令归 ReadWrite、describe 未列 = 非
      Root 拒——与 SC 侧完全一致）；ACL 不套 group 命令（组跨主题，读数据时的
      fetch 已有 ACL；这是边界不是遗漏，留痕）

**执行中的两处实际修法（与立项时的差异）**：① `CMD_LEADER` 需要 serve 应答——成员靠它解析
取数地址，serve 没有这个臂时 `leader_of` 返回 None、成员**静默读不到任何记录**（腿 1 的份额
断言通过、数据零投递，是这条的第一现场）；应答"this one"，权限表随之把 CMD_LEADER 归入
`is_data_read`（能读数据的人必须能找到数据；保留在 `is_node_command`，节点兜底不受影响）。
② 组客户端的凭据此前只读 `MOONFLUX_TOKEN` 环境变量（`group_link()`），`--token` 的成员在
认证之下第一句就被 `ERR_AUTH_REQUIRED` 拒——集群侧同样存在，只是 p9 门禁跑在无认证之下从未
暴露。修法是把 token 作为参数穿过整条组路径（`client_token` 口径：旗标优先、环境兜底）。
