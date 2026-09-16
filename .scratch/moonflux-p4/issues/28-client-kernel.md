# 28 — 客户端内核化（浏览器可编译的客户端）

**What to build:** 把客户端里**纯逻辑**的部分（帧编解码、握手、Producer/Consumer 语义、请求
id 校验）从原生传输里剥出来，成为一个**全后端可编译**的包；传输仍是注入式函数字段（原生 TCP /
浏览器 WebSocket / 测试用 socketpair），因此同一份客户端逻辑能在 native 与 wasm-gc 上跑。

**Blocked by:** 27（读语义先定稿，避免客户端语义再动两次）。

**Status:** ready-for-agent

- [ ] 新包 `core/client`（或 apps/client-core）：帧/载荷编解码 + 会话状态机，零平台依赖，
      `supported_targets` 不声明（= 全后端）
- [ ] `apps/client` 退化为"原生传输 + 转出"的薄层（既有 API 不变，避免全仓连锁修改）
- [ ] 单测在 wasm-gc 与 native 双后端跑通（同一批断言）；socketpair 传输用于无网络单测
- [ ] `apps/cli` 与既有门禁零回归
