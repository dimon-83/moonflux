# 61 — SC 控制面接入 ConnectionHub

**What to build:** `cmd_sc` 的"accept → 同步处理完一条连接 → 关掉"换成与 `serve`/`spu` 同构的
`ConnectionHub` 循环：hub 负责接受/握手/TLS/认证，本里程碑只需一个**逐帧分发器**。

- `dispatch_control_frame(frame, table, placement, store, groups, asset, identity) -> (Int, Bytes)`：
  从 `handle_control_connection` 的 `while true { recv_frame … }` 主体机械拆出（`match frame.cmd { … }` 部分
  原样保留，含 P12 的 `permit` 前置判定——它现在由 hub 传入的 `identity` 驱动，语义不变）；
- `HubHandler{on_frame, auth: AuthGate, on_ready}`：hub 在 `Frames` 之前处理 `CMD_AUTH` 并维护每连接身份
  （P12 已实现），因此 SC 不再自己写 HELLO/WELCOME/AUTH 状态机；
- 主循环：`hub.poll_once(handler, …)` 之后做 housekeeping（`groups.sweep` / `table.sweep` / `placement.tick`），
  间隔由 `poll_once` 的 poll 超时兜住；
- **删除**：`handle_control_connection`、`control_conn`、`CONTROL_HANDSHAKE_DEADLINE_MS`，以及
  `apps/client` 的 `accept_tls_conn`（服务端阻塞握手只剩 hub 一条路——一份实现，不是两份）；
- 保留 `conn_over_stream`（节点**出站**调用仍需要它：TLS 会话没有 SO_RCVTIMEO）。

**Blocked by:** None（P12 的 hub/TLS/注册表都在）。

**Status:** done (2026-09-17)

- [ ] 分发器拆出，行为逐条不丢：REGISTER/HEARTBEAT（含 assignments/floors/revision 应答）、NODES、TOPIC_*、
      FUNCTION_SET_*、GROUP_*（JOIN/HEARTBEAT/LEAVE/COMMIT/DESCRIBE）、CLUSTER_PIPELINE_APPLY/FETCH、
      FUNCTION_SET_FETCH、LEADER、PRODUCE/FETCH 的角色拒绝、未知命令；
- [ ] `sc` 用 hub：TLS 由 `tls_listener(flags)` 配置（与 `serve`/`spu` 同一处读 flags），认证走 `AuthGate`；
- [ ] housekeeping 仍在 poll 之间跑：节点/组存活清扫与 `placement.tick`；
- [ ] 启动日志仍逐条明示（listen / 认证模式 / TLS），并加一行"服务多条连接（单线程 poll 驱动）"与数据面同构；
- [ ] 删除的阻塞路径不留残骸（`grep accept_tls_conn` 为空）；`moon check` 干净，既有 30 步门禁不回退。

### 关账（2026-09-17）

落地：`dispatch_control_frame(frame, …, identity) -> (Int, Bytes)` 从阻塞处理器机械拆出（命令分支逐条保留，
含 P12 的 `permit` 前置判定），`cmd_sc` 改为 `ConnectionHub` 循环（`tls_listener(flags)` + `AuthGate` +
poll 之间的存活清扫/放置 reconcile），启动多打一行 `serving connections concurrently (one thread, poll-driven)`
与数据面同构。**删除**：`handle_control_connection`、`control_conn`、`accept_tls_conn`
（服务端阻塞 TLS 握手只剩 hub 一条路）与 `CONTROL_HANDSHAKE_DEADLINE_MS`（改为 hub 参数的
`CONTROL_HANDSHAKE_DEADLINE_MS = 500` 仍保留为期限值，但已无阻塞可限）。

**一个真错**：拆出来的分发器最初漏了 `CMD_HELLO` 分支——`serve` 与数据节点都是"hub 把握手帧也交给分发器"，
所以控制面必须自己答 WELCOME（首版回了 `CMD_OK`，`mfs_probe` 立刻报 `unexpected handshake reply: cmd 5`）。
这正是"每帧分发器"契约的一部分，已写进注释。
