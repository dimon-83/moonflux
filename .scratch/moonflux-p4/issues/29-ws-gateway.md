# 29 — WebSocket 网关（浏览器传输）

**What to build:** `serve --ws`（或同端口升级）：浏览器能连的传输，**协议不变**——WS 帧里
装的还是 `MFS` 帧，网关只做 WebSocket 握手与分帧搬运，不解释业务载荷。这是"一个协议多种传输"
的落地，也是浏览器唯一可行的路径（浏览器没有 raw TCP）。

**Blocked by:** 28（客户端内核化后，网关与浏览器端共享同一份帧编解码）。

**Status:** ready-for-agent

- [ ] WS 握手（HTTP Upgrade + Sec-WebSocket-Accept）、帧读写（文本/二进制、掩码、分片最小集）
- [ ] 与既有 TCP 路径**共用** `dispatch_*` 处理器（不允许出现第二套命令语义）
- [ ] 单测：握手向量（RFC 示例 Accept 值）、掩码解码、分片拼接
- [ ] E2E：脚本级 WS 客户端（python 内置库）走完 HELLO→PRODUCE→FETCH
