# 21 — 节点形态：spu / sc 子命令 + 身份、心跳与注册

**What to build:** 单程序多子命令的节点形态（AGENTS §1.2）：`spu`（数据节点）与 `sc`
（控制节点）两个子命令，各自持有身份与数据目录；节点间复用 `apps/client` 的帧协议 v2，
新增控制类命令（注册 / 心跳 / 节点清单）。`serve` 保持为"全在一体"的单节点形态（向后兼容，
既有门禁不许回归）。

**Blocked by:** 19（节点身份与 Spec 类型）。

**Status:** ready-for-agent

- [ ] 协议 v2 扩展：`CMD_REGISTER` / `CMD_HEARTBEAT` / `CMD_NODES`（+ 复用 OK/ERR）；
      请求载荷 = 节点身份（id、角色、地址）+ LEO 进度（后续 22/23 用到）
- [ ] `spu` 子命令：`--id --listen --data-dir [--sc addr]`；启动即向 SC 注册并周期心跳
- [ ] `sc` 子命令：`--listen --data-dir`；接受注册、维护节点清单（存活/超时由注入式时钟判定）、
      对外提供 `nodes` 查询
- [ ] 节点身份持久化：`<data-dir>/node.json`（id + 角色）；重启身份不变
- [ ] E2E 小脚本：本地起 sc + 两个 spu，`nodes` 能列出三者；杀掉一个 → 超时判定为离线
- [ ] 既有行为不回归：`serve` 路径与全部既有门禁保持绿
