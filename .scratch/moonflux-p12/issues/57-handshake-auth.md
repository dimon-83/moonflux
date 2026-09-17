# 57 — 握手期认证

**What to build:** 凭据在**握手期**交换：HELLO/WELCOME 之后、任何业务命令之前，客户端必须发 `CMD_AUTH`
（加法命令）。服务端在认证通过前**不服务任何命令**（返回结构化的"需要认证"）；认证后按其角色逐命令判定。
节点身份与客户端身份分开（`Node` 角色），复制路径必须带节点凭据。
**未配置认证（`auth.json` 不存在或为空）→ 行为与今天完全一致**，但启动时**明说**正在无认证运行。

**Blocked by:** 56.

**Status:** done (2026-09-17)

- [x] 协议：`CMD_AUTH = 35`（载荷 = token），应答 = 角色名或结构化拒绝；
- [x] 服务端：三条路径都要接（hub 会话、SC/SPU 控制连接、`serve` 单连接），且都是"认证前不服务"；
- [x] 客户端：`core/client` 的会话在 HELLO 之后发 AUTH（凭据由调用方注入，内核不读环境）、`--token` /
      `MOONFLUX_TOKEN`，节点进程的 `--token`（对 SC 与对 leader 都用）；
- [x] 权限判定接在**命令分发的最外层**（一处判定，不许每个 handler 自己写）；
- [x] 单测/门禁腿：无凭据被拒、坏 token 被拒、只读不能写、节点命令拒绝客户端身份

### 关账（2026-09-17）

落地：`CMD_AUTH = 35` 与错误码 `ERR_AUTH_REQUIRED = 9` / `ERR_FORBIDDEN = 10`（两者区分"先说你你是谁"与"不是你"）；
**三处服务端**——hub（带每连接身份状态：这是它的地盘，因为它已经拥有握手）、SC/SPU 控制连接、SPU 数据端口——
全部"认证前不服务"；权限判定放在**每个分发的入口一处**（新增命令无法绕过）；客户端内核 `handshake_with(conn, token)`
与 `from_conn_with`（**token 是参数，内核不读环境**：库若自己读凭据文件，它的每个嵌入者都会替它做一个它没做的安全决定）、
`connect_{producer,consumer}_with`、CLI 侧 `--token` / `MOONFLUX_TOKEN`；节点侧凭据贯穿注册/心跳/领导视图/确认/复制链接。
**默认关闭且启动明示**（`authentication DISABLED (...): every connection is trusted`），既有 29 步门禁零改动全绿。

**冒烟实测**：无凭据 → `code 9 authenticate first`；错 token → `code 9 unknown credential`；只读生产 → `code 10 dash (read-only) may not issue command 3`；只读消费 ✓；只读删主题 → `code 10`；read-write 生产 ✓。
