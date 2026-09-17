# 58 — TLS 传输

**What to build:** `adapters/tls-native`：经 C shim + **dlopen** 使用 OpenSSL（与 wasmtime 宿主同一模式：
**能力可缺席**——没有 libssl 时只有 TLS 不可用，其余功能完好；`MOONFLUX_TLS_LIB` 可覆盖路径）。
服务端：接受 TCP 后做 TLS 握手（服务端证书；节点间可选**双向**）；客户端：`Conn` 的 TLS 传输构造器。
**传输抽象要升级**：hub 与 SyncLink 现在绑在 `@net.TcpStream` 具体类型上，改成注入式接口（与 `Conn` 同构），
TLS 与明文共用同一条代码路径。非阻塞 TLS 的两个坑必须显式处理：`SSL_ERROR_WANT_READ/WRITE` 循环、
**`SSL_pending`（TLS 缓冲里可能已有数据而 fd 不再可读）**。

**Blocked by:** 57（握手期认证先落地，TLS 只是把凭据与数据一起保护起来）。

**Status:** done for the client/server path (2026-09-17); node-to-node TLS is ticket 59

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

### 关账（2026-09-17）

**根因（三个，都在一行之内）**：C shim 的 `mf_tls_write` 取 `(ssl, buf, len)` 而 MoonBit extern 只传 `(ssl, buf)`——
`len` 从垃圾寄存器读出，于是 `SSL_write` 写出越界内容（表现为"客户端说握手完成、服务端看到明文"）。同类的错位在这一轮里
共修了三处（ctx 构造器的长度参数、写路径的 len、句柄的 32 位截断），所以现在**逐个核对过 extern 与 C 的签名**。
第四条：`SSL_get_error` 必须用上一次调用的返回值（原来传 -1 重问，方向判断不可靠）。

**关键发现（安全性实质漏洞）**：OpenSSL 客户端的默认 verify 模式是 `SSL_VERIFY_NONE`——**装载了 CA 却不要求校验，
握手照样成功、CA 只是装饰**。第一版就是这样：错 CA 的客户端照样读到了数据 ✗。现在 `mf_tls_client_ctx` 一律
`SSL_CTX_set_verify(VERIFY_PEER)`，并配合 `SSL_set1_host`（主机名钉住）；错 CA 得到
`certificate verify failed (code 20)` ✓。

**进程内握手测试**（`adapters/tls-native/tls_wbtest.mbt`）：socketpair 上两个会话**交替步进**（无线程），
证书路径由环境变量给出（门禁生成；没有证书就跳过并说明）。它正是抓住 `tls_write` 错位的那个测试。

**实测四例**：正确 CA 可 produce/consume ✓；错 CA 被拒（code 20）✓；明文客户端打 TLS 端口被拒**且服务端存活** ✓；
之后 TLS 仍正常 ✓。服务端日志把两种拒绝连同 openssl 原因都记下来 ✓。
