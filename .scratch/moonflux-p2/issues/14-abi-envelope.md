# 14 — 算子 ABI 信封与模块格式（纯计算部分）

**What to build:** 算子沙箱的内核侧：ABI v1 契约的类型与编解码（纯计算、全后端可编译）——
算子模块的调用信封（init 配置载荷 / process 输入输出载荷 = RecordBatch 帧复用）、
ABI 版本协商字段、宿主侧算子描述（模块路径 + 导出名 + 预算档位）。本 ticket 不含任何
wasm 执行，执行件在 15；信封先用一个"透传算子"的进程内假实现钉死语义（对拍可跑）。

**Blocked by:** None — can start immediately.

**Status:** ready-for-agent

- [ ] `core/operator` 包：`OperatorSpec{ module_path, exports, budget_tier }`、
      ABI v1 常量与载荷编解码（复用 core/protocol 帧）；宿主接口 `OperatorEngine`
      （函数字段注入：instantiate / call_process），与 SegmentFile/Conn 同风格
- [ ] 进程内参考实现 `PassthroughEngine`（原样返回输入），供 17 的语义对拍基线与单测
- [ ] 预算档位常量（复用 P1 分级经验：内部/用户/租户三档，宿主执行超时→结构化错误）
- [ ] 单测：信封往返、版本不匹配拒绝、预算档位校验；双后端通过
