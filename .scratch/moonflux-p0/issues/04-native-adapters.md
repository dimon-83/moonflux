# 04 — fs-native / net-native 适配层

**What to build:** 两个单目标薄适配包立起来并各自可验证：fs-native 提供文件打开/读/写/追加/大小/列目录（libc FFI + native-stub）；net-native 提供阻塞 TCP socket/connect/accept/send/recv/close 与最小握手助手。两者都通过 `supported_targets = "native"` 编译期钉死在 native；它们是数据面外设读写（P0 demo）与协议服务化（P1）的地基。

**Blocked by:** 01（可与 02/03 并行）。

**Status:** done (2026-09-15)

- [x] `adapters/fs-native`：`File`（open_read/open_write_or_create/open_append/close/read_at/append/size/flush）、目录创建（mkdir -p 语义）、文件删除；错误映射为结构化 FsError（errno 保留）
- [x] `adapters/net-native`：`TcpListener`（bind/listen/accept）、`TcpStream`（connect/send_all/recv/close）；主机:端口解析助手；结构化 NetError
- [x] fs-native 集成测试（native）：写→读→追加→size→删除 往返；临时目录内自清理
- [x] net-native 冒烟测试（native，进程内无并发）：socketpair 往返 send/recv；解析助手单测
- [x] 两个包 `moon build --target wasm-gc` 必须编译期 fail-fast（supported_targets 生效验证）
