# 12 — 协议服务化 v2 + 客户端 SDK 雏形

**What to build:** 把 P0 内部会话帧升级为正式版本化命令协议：Hello 握手（版本协商，客户端版本过高→结构化拒绝）、命令帧带请求 id、错误帧带稳定错误码；抽 `apps/client` SDK 库（Producer/Consumer，连接抽象为注入流以便 socketpair 单测），CLI `--remote` 路径改走 SDK。协议入兼容性矩阵。

**Blocked by:** 10.

**Status:** ready-for-agent

- [ ] 协议 v2：Hello{major,minor}→Welcome/Err(unsupported)；帧头含请求 id；错误码枚举（unsupported-version/unknown-command/bad-payload/storage…）
- [ ] `apps/client`：`Producer::send(topic, records)`、`Consumer::fetch(topic, from, max)`；连接抽象（注入 send/recv 函数字段）；CLI --remote 重构为 SDK 调用
- [ ] socketpair 单测：SDK 全流程（握手→produce→fetch→错误路径）进程内可测；serve 端协议单测
- [ ] e2e-p0.sh 远程路径继续绿（重构不回归）；握手不匹配的旧客户端被拒（E2E 或单测断言）
- [ ] docs/compatibility-matrix.md 增补协议服务化条目（状态+证据）
