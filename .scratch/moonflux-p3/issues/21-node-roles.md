# 21 — 节点形态：spu / sc 子命令 + 身份、心跳与注册

**What to build:** 单程序多子命令的节点形态（AGENTS §1.2）：`spu`（数据节点）与 `sc`
（控制节点）两个子命令，各自持有身份与数据目录；节点间复用 `apps/client` 的帧协议 v2，
新增控制类命令（注册 / 心跳 / 节点清单）。`serve` 保持为"全在一体"的单节点形态（向后兼容，
既有门禁不许回归）。

**Blocked by:** 19（节点身份与 Spec 类型）。

**Status:** ✅ done (2026-09-16)

- [x] 协议 v2 扩展：`CMD_REGISTER` / `CMD_HEARTBEAT` / `CMD_NODES`（+ 复用 OK/ERR）；
      请求载荷 = 节点身份（id、角色、地址）+ LEO 进度（后续 22/23 用到）
- [x] `spu` 子命令：`--id --listen --data-dir [--sc addr]`；启动即向 SC 注册并周期心跳
- [x] `sc` 子命令：`--listen --data-dir`；接受注册、维护节点清单（存活/超时由注入式时钟判定）、
      对外提供 `nodes` 查询
- [x] 节点身份持久化：`<data-dir>/node.json`（id + 角色）；重启身份不变
- [x] E2E 小脚本：本地起 sc + 两个 spu，`nodes` 能列出三者；杀掉一个 → 超时判定为离线
- [x] 既有行为不回归：`serve` 路径与全部既有门禁保持绿

## 落地记录

- **协议扩展**：`CMD_REGISTER=7` / `CMD_HEARTBEAT=8` / `CMD_NODES=9`；新增错误码
  `ERR_WRONG_ROLE=7`（数据命令打到控制端口 → 结构化拒绝，不做静默代理）。
  节点记录 = uleb128 长度前缀的 UTF-8 字段 + varint LEO（`encode_node`/`decode_node`/
  `encode_nodes`/`decode_nodes`）；未知角色名拒绝而非默认（打错字不该变成数据节点）。
- **节点形态**：`spu --id A --listen host:port [--data-dir D] [--sc addr]`（数据面照旧 +
  向控制面报到）、`sc --listen host:port [--data-dir D]`（控制面）、
  `cluster nodes --remote host:port`（看一眼控制面知道什么）。`serve` 原样保留为
  "全在一体"的单节点形态，既有门禁未回归。
- **身份持久化**：`<data-dir>/node.json`；重启是**同一个节点回来**（命令行 `--id` 不覆盖
  已存身份）——这正是后续 rejoin 语义的前提。
- **单线程分层**：两个循环都是 单个线程 + 监听超时（500ms 心跳 / 3s 存活判定），
  交替"服务请求"与"做家务"（心跳、存活扫描、后续调和 tick）。没有后台线程 = 故障注入
  时没有隐藏并发。
- **存活是推导出来的**：`NodeTable` 只记 `last_seen`，离线由时钟推导；下线转换**只报一次**
  （level-triggered，不是每 tick 的日志流）——门禁脚本对此有断言。
- 三个真实的坑（均已修，且都是"看起来能跑"的反面教材）：
  1. **macOS 的 `SO_RCVTIMEO` 不作用于 `accept()`**（只管 recv）⇒ 监听超时改为
     `poll()` + accept 的 shim 调用（`mf_net_accept_timeout`），超时值存在 listener 上。
     症状是"节点永远不报到"，因为循环卡死在一个永不超时的 accept 上。
  2. **`@env.now()` 是毫秒**，我按纳秒除了 1e6 ⇒ 3 秒的存活超时变成 3000 秒。
  3. **重定向的 stdout 是块缓冲**：长驻节点（serve/spu/sc）的日志在运行期读不到，
     被信号杀掉时更是全部丢失 ⇒ 新增 `apps/cli/cli_shim.c` 的 `fflush` 与 `note()`
     （打印即刷新），集群事件从此可观测。
- 测试：`apps/cli/node_wbtest.mbt`（4 项，节点表转换语义）+ `adapters/net-native`
  新增 2 项（accept/recv 超时，含"超时后仍能正常收发"）；门禁脚本 `scripts/e2e-p3-nodes.sh`
  5 条断言全绿，已纳入 `scripts/gates.sh`。全量：native 133/133、wasm-gc 98/98、16 步门禁全绿。
