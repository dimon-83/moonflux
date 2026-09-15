# 00 — P1 里程碑概览（连接器与外设）

**门禁（可证伪）**
- ≥3 个真实数据源接入跑通（file / stdin / HTTP GET）
- 改规则秒级生效（不重启运行中的 serve，改 spec→apply 后新规则即生效）

**范围（依据 README 路线图 P1 行 + AGENTS §8）**
- mbel 表达式 transforms（Native 内嵌；compile-once + Vm 缓存 + budget 分级；发布期静态检查）
- Source/Sink 框架雏形：file、stdin、http-get 三源 + stdout、http-post 双汇
- 协议服务化：P0 会话帧升级为带握手的版本化协议 + 客户端 SDK 雏形（apps/client）
- 明确不做：多路复用/并发连接（仍顺序单连接，P2/P3）、MQTT/Kafka 连接器、多分区、复制

**Tickets（依赖序）**
- 09 mbel transform 执行件（无阻塞）
- 10 transforms 接入数据路径 + 规则热重载（blocked by 09）
- 11 连接器框架 + ≥3 数据源（无阻塞，可与 09/10 并行）
- 12 协议服务化 v2 + 客户端 SDK（blocked by 10）
- 13 P1 门禁验证 + 文档同步（blocked by 10, 11, 12）

**状态**
- [ ] 09 … [ ] 13（各 ticket 文件内有独立 checklist）
