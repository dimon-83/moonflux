# 58 — TLS 传输

**What to build:** `adapters/tls-native`：经 C shim + **dlopen** 使用 OpenSSL（与 wasmtime 宿主同一模式：
**能力可缺席**——没有 libssl 时只有 TLS 不可用，其余功能完好；`MOONFLUX_TLS_LIB` 可覆盖路径）。
服务端：接受 TCP 后做 TLS 握手（服务端证书；节点间可选**双向**）；客户端：`Conn` 的 TLS 传输构造器。
**传输抽象要升级**：hub 与 SyncLink 现在绑在 `@net.TcpStream` 具体类型上，改成注入式接口（与 `Conn` 同构），
TLS 与明文共用同一条代码路径。非阻塞 TLS 的两个坑必须显式处理：`SSL_ERROR_WANT_READ/WRITE` 循环、
**`SSL_pending`（TLS 缓冲里可能已有数据而 fd 不再可读）**。

**Blocked by:** 57（握手期认证先落地，TLS 只是把凭据与数据一起保护起来）。

**Status:** in progress (session layer and plumbing land; the handshake does not complete yet — see the overview's three findings)

- [ ] `adapters/tls-native`：`tls_connect(ca, cert?, key?)`、`tls_accept(stream, cert, key)`、`tls_pending`、
      `send_some/recv_some/close` 的 SSL 版本；无 libssl 时返回结构化"该能力不可用"
- [ ] 传输抽象：hub/SyncLink/control_call 改用接口而非具体 TcpStream；明文与 TLS 两条构造器
- [ ] CLI：`--tls-ca/--tls-cert/--tls-key`（客户端与服务端各自），`scripts/gen-dev-certs.sh` 生成自签证书
- [ ] 文档写明边界：TLS 保护传输，**不**替代授权（角色判定仍在应用层）

### 进度（2026-09-17，未完成）

**已落地并编译**：`adapters/tls-native`（OpenSSL dlopen shim + 会话层，句柄经 `Int64`）；`@net.Stream` 传输抽象与
`poll_fds(..., want_write)`；hub 的 TLS 接入（`with_tls` + 有界阻塞握手：accept 后在阻塞 socket 上带 2s 期限握手，
之后数据路径非阻塞）；`apps/client` 的 `tcp_tls`（含主机名校验 `SSL_set1_host` 与 `SSL_get_verify_result`）。

**未完成**：服务端与客户端握手不一致（客户端认为完成、服务端看到明文）。**已撤掉 `--tls-*` 入口**，避免半成品可达。

**顺带修掉的既有 bug**：`net-native` 的 `poll_readable` 把 C shim 的**标志位当成了下标**——单连接时下标 1 越界直接
panic（多连接时则错服务连接）。这个 bug 从 P5 起就在，靠"只影响公平性不影响正确性"活到了 TLS 把它变成致命。
