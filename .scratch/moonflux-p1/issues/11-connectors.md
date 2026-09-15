# 11 — 连接器框架 + ≥3 真实数据源

**What to build:** Source/Sink 框架雏形（函数字段注入，与 SegmentFile 同风格）：三个真实数据源 file / stdin / http-get，两个 sink stdout / http-post；spec 的 source.type/sink.type 扩展并通过 pipeline run 执行。达成门禁「≥3 个真实数据源接入跑通」。

**Blocked by:** None — 可与 09/10 并行.

**Status:** ready-for-agent

- [ ] `apps/connectors`：Source/Sink 函数字段接口；HTTP/1.1 GET/POST 最小实现（net-native 之上，响应头解析、body 按行拆分）
- [ ] core/spec：source.type ∈ {file, http, stdin}（http 带 url 字段）；sink.type ∈ {stdout, http}（http 带 url）；core/pipeline compile 映射
- [ ] `pipeline run` 支持三种 source 与两种 sink 的组合执行；CLI produce/consume 的 --file/--remote 语义保留
- [ ] `scripts/e2e-p1-connectors.sh`：python3 起真实 HTTP fixture（GET 数据 + POST 收集）；http-get→stdout、stdin→http-post、file→stdout 三条链 diff 断言
- [ ] 集成测试：HTTP 状态码非 200 → 结构化错误；响应无 body → 空记录集
