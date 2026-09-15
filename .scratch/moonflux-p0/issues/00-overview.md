# 00 — P0/P0′ 里程碑概览（moc：本文件只做索引，不含实现）

**目标**：达成 P0「Native 最小闭环」与 P0′「PipelineSpec v1alpha1 + 编译/计划」两个里程碑及其门禁。

**门禁（可证伪）**
- P0：端到端 demo 可复现（文件源 → topic → stdout）；协议样本对拍通过。
- P0′：一份 PipelineSpec 可编译为可运行的进程拓扑；`plan` 输出差异预览。

**范围裁剪（本里程碑明确不做，依据 AGENTS §2 / README 路线图）**
- TCP 上的完整版本化协议服务化与客户端 SDK → P1（本里程碑只交付最小 framed 会话协议，仅供 demo 使用）
- mbel 表达式 transforms → P1（PipelineSpec 中保留 transforms 字段占位并校验其形态）
- retention / 多分区 / 复制 / 选主 → P3
- WASM 算子沙箱 → P2（但内核包从第一天保持全后端可编译，由 CI 矩阵纪律保证）

** Tickets（依赖序）**
- 01 工程骨架 + 内核 codec 原语（无阻塞）
- 02 线协议 Record/Batch 编解码 + golden vectors（blocked by 01）
- 03 分区日志：接口 + 内存实现（blocked by 02）
- 04 fs-native / net-native 适配层（blocked by 01，可与 02/03 并行）
- 05 日志文件持久化 + CLI produce/consume + P0 端到端 demo（blocked by 03, 04）
- 06 协议样本对拍脚本与兼容性矩阵（blocked by 02）
- 07 PipelineSpec v1alpha1（blocked by 01，可与 02–04 并行）
- 08 pipeline plan/apply/run + P0′ 端到端（blocked by 05, 07）

**状态**
- [ ] 01 … [ ] 08（各 ticket 文件内有独立 checklist）
