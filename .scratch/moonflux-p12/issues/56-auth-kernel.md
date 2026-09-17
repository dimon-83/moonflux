# 56 — 内核鉴权语义

**What to build:** `core/auth`：**身份 → 角色 → 命令权限**的纯计算内核。身份有名字与角色；角色分
`Root`（全部）/ `ReadWrite`（数据面 + 自己的消费组）/ `ReadOnly`（只读）/ `Node`（节点间命令：注册、
心跳、复制、确认）；`permit(role, cmd) -> Bool` 是一张**显式表**（新增命令必须显式入表，否则默认拒绝——
默认开放是安全面最容易犯的错）。token 比较**常数时间**。

**Blocked by:** None.

**Status:** done (2026-09-17)

- [x] `Type Identity{name, role}`、`Role{Root, ReadWrite, ReadOnly, Node}`、`permit(role, cmd)`、
      `constant_time_eq(a, b)`
- [x] 权限表的依据写进注释：**节点间命令只对 `Node`**（今天的漏洞：任何连接都能注册假节点、伪造 SYNC_ACK
      水位）；控制面写命令（topic/函数集/管道）只对 `Root`；数据面读只读即可、写需 `ReadWrite`
- [x] `authenticate(expected : Array[(String, String, Role)], token) -> Identity?`（名字、token、角色三元的表）
- [x] 单测：每个角色的允许/拒绝矩阵（含"未知命令默认拒绝"）、常数时间比较（长度不同/内容不同/相同）、
      表里没这个名字 → None

### 关账（2026-09-17）

落地 `core/auth`（内核包，四后端可编译）：`Identity`/`Role{Root, ReadWrite, ReadOnly, Node}`、**闭合的权限表**
`permit(role, cmd)`（未列出的命令对非 Root 一律拒绝——新增命令忘了分类是"测试会发现的拒绝"，不是"没人发现的开门"）、
`Credential`/`authenticate`、**常数时间比较** `constant_time_eq`（`==` 会在第一个不同字节返回，足以用秒表逐字节
恢复 token）。角色模型沿用参考系统的 Root/ReadOnly/Basic 思路并**加了 Node**：复制的信任与读数据的信任不是
一回事——能伪造 `SYNC_ACK` 就能推动所有人的 committed read 依赖的高水位。单测 4/4，含"未知命令默认拒绝"与
"空配置认证不了任何人"。
