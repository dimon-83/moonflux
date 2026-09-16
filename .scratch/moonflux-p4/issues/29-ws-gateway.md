# 29 — WebSocket 网关（浏览器传输）

**What to build:** `serve --ws`（或同端口升级）：浏览器能连的传输，**协议不变**——WS 帧里
装的还是 `MFS` 帧，网关只做 WebSocket 握手与分帧搬运，不解释业务载荷。这是"一个协议多种传输"
的落地，也是浏览器唯一可行的路径（浏览器没有 raw TCP）。

**Blocked by:** 28（客户端内核化后，网关与浏览器端共享同一份帧编解码）。

**Status:** ✅ done (2026-09-17)

- [x] WS 握手（HTTP Upgrade + Sec-WebSocket-Accept）、帧读写（文本/二进制、掩码、分片最小集）
- [x] 与既有 TCP 路径**共用** `dispatch_*` 处理器（不允许出现第二套命令语义）
- [x] 单测：握手向量（RFC 示例 Accept 值）、掩码解码、分片拼接
- [x] E2E：脚本级 WS 客户端（python 内置库）走完 HELLO→PRODUCE→FETCH

## 落地记录

- **形态：同一端口嗅探，而非第二个监听**。`serve --ws` 打开嗅探：连接的前 4 字节是 `GET ` 就走
  WebSocket（握手 → `ws_transport`），否则**把那 4 字节还给帧路径**（`prefixed_transport`）——
  一个端口同时服务浏览器与 CLI，不需要第二个端口、也不需要客户端改标志。协议一个字节没变：
  WS 二进制帧里装的还是 `MFS`。
- **WS 实现**（`apps/cli/ws.mbt`，原生层——握手是传输关注点）：SHA-1 + Base64 + RFC 6455 握手、
  帧读写（长度 7/16/64 位、**客户端必须带掩码否则拒绝**——接受未掩码输入是代理投毒口子而不是便利）、
  分片重组、ping→pong、close。`ws_transport` 把连接包装成 `Conn`，于是**上面所有代码
  （帧编解码、命令分发、处理器）与 TCP 路径完全共用**。
- **拒绝要有理由**：非 upgrade 的 HTTP 请求得到 `400 Bad Request` 并写明原因（此前是静默断开）。
  门禁对此有断言：不能把一个到达了正确端口的请求无声丢掉。
- **门禁**：`scripts/e2e-p4-ws.sh` 3 条断言——真实 WebSocket 客户端（python 手写握手 + 掩码帧）
  完成 HELLO→PRODUCE→FETCH，且**取回的帧与发送的帧逐字节相同（仅 base offset 由 broker 指派）**；
  同端口上 CLI 的 TCP 路径照常读写；非 upgrade 请求得到带原因的 400。
- 测试：`apps/cli/ws_wbtest.mbt`（5 项）——SHA-1 三条标准向量（FIPS `abc`、空串、跨块）、
  **RFC 6455 §1.3 的 accept key 算例**、Base64 填充、HTTP 嗅探、掩码帧往返、未掩码被拒、pong 应答。
- 工具：`tools/gen_ws_batch.py` 不再手写字节，而是**取项目自己的 golden vector**
  （`core/protocol/testdata/protocol_vectors.json` 的 multi-record）并把 base offset 改成 -1——
  之所以能这么改而不重算 CRC，正是设计里"base offset 不入 CRC"的用途。
