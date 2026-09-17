# 58 — TLS 传输

**What to build:** `adapters/tls-native`：经 C shim + **dlopen** 使用 OpenSSL（与 wasmtime 宿主同一模式：
**能力可缺席**——没有 libssl 时只有 TLS 不可用，其余功能完好；`MOONFLUX_TLS_LIB` 可覆盖路径）。
服务端：接受 TCP 后做 TLS 握手（服务端证书；节点间可选**双向**）；客户端：`Conn` 的 TLS 传输构造器。
**传输抽象要升级**：hub 与 SyncLink 现在绑在 `@net.TcpStream` 具体类型上，改成注入式接口（与 `Conn` 同构），
TLS 与明文共用同一条代码路径。非阻塞 TLS 的两个坑必须显式处理：`SSL_ERROR_WANT_READ/WRITE` 循环、
**`SSL_pending`（TLS 缓冲里可能已有数据而 fd 不再可读）**。

**Blocked by:** 57（握手期认证先落地，TLS 只是把凭据与数据一起保护起来）。

**Status:** ready-for-agent

- [ ] `adapters/tls-native`：`tls_connect(ca, cert?, key?)`、`tls_accept(stream, cert, key)`、`tls_pending`、
      `send_some/recv_some/close` 的 SSL 版本；无 libssl 时返回结构化"该能力不可用"
- [ ] 传输抽象：hub/SyncLink/control_call 改用接口而非具体 TcpStream；明文与 TLS 两条构造器
- [ ] CLI：`--tls-ca/--tls-cert/--tls-key`（客户端与服务端各自），`scripts/gen-dev-certs.sh` 生成自签证书
- [ ] 文档写明边界：TLS 保护传输，**不**替代授权（角色判定仍在应用层）
