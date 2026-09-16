# 28 — 客户端内核化（浏览器可编译的客户端）

**What to build:** 把客户端里**纯逻辑**的部分（帧编解码、握手、Producer/Consumer 语义、请求
id 校验）从原生传输里剥出来，成为一个**全后端可编译**的包；传输仍是注入式函数字段（原生 TCP /
浏览器 WebSocket / 测试用 socketpair），因此同一份客户端逻辑能在 native 与 wasm-gc 上跑。

**Blocked by:** 27（读语义先定稿，避免客户端语义再动两次）。

**Status:** ✅ done (2026-09-17)

- [x] 新包 `core/client`（或 apps/client-core）：帧/载荷编解码 + 会话状态机，零平台依赖，
      `supported_targets` 不声明（= 全后端）
- [x] `apps/client` 退化为"原生传输 + 转出"的薄层（既有 API 不变，避免全仓连锁修改）
- [x] 单测在 wasm-gc 与 native 双后端跑通（同一批断言）；socketpair 传输用于无网络单测
- [x] `apps/cli` 与既有门禁零回归

## 落地记录

- **分层**：`core/client`（内核侧，纯计算，不声明 `supported_targets` = 全后端）承载
  **帧编解码 + 会话状态机 + Producer/Consumer**；`apps/client` 只剩**原生传输**
  （`tcp` / `tcp_with_timeout` / `from_stream` / `socketpair` + `connect_producer/consumer`）。
  理由写在包头：浏览器打不开 TCP，而编辑器需要 CLI 用的同一份客户端逻辑——一份协议实现、
  多个传输（TCP / WebSocket / 内存对），这正是 AGENTS §1 规则 2 的形状。
- **传输契约仍是 `Conn`**（注入式函数字段），因此测试可以在**无 socket** 的情况下跑：
  新增 `Conn::memory_pair()`（内核内的内存双向对，写即入对端缓冲、读即消费，语义与 socket 版
  一致但不含 OS）。**客户端 12 项测试现在在 native 与 wasm-gc 双后端都跑**（这正是本 ticket
  的目的：以前它们只在有 socket 的后端可跑）。
- **两个 MoonBit 语言边界（实测）**：
  1. `pub using` 是**源码级**结构，不能写在 `moon.pkg` 里（会报解析错误）；
  2. 可以再导出**类型与函数**，但**不能再导出枚举构造器**（`type FirstRead` 不会把 `Got` 带过来，
     写 `Got,` 会被当成类型名找不到）。结论：需要构造器的调用方直接 import 内核包。
     因此 `apps/cli` 同时 import `core/client`（协议与会话）与 `apps/client`（传输构造器）。
  3. 不能给**外部类型**定义方法（`Conn::tcp` 在别的包里非法）⇒ 传输构造器是**自由函数**
     （`@native.tcp(...)`、`@native.connect_producer(...)`）。这反而更贴切：构造方式是传输的属性，
     不是管道的属性。
- 迁移期发现并修掉：`wrap_stream` 在文件搬迁中丢失（`recv_exact` 的短读/EOF 语义就靠它），
  已按原语义恢复并加了注释；`apps/client` 的测试整体搬到 `core/client`（纯逻辑），
  传输相关留在原生包。
- 全量：native 150/150、wasm-gc **115/115**（+12 客户端内核测试）、四后端 0 error、
  11 个门禁脚本复跑全绿。
