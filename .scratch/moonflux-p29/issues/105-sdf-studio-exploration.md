# T105 · SDF Studio 对标探索（docs/sdf-studio-exploration.md）

**What to build**: 一份探索文档：Studio 的事实（两种节点、两种边、点边信息栏、Metrics/state 表、`sdf run --ui` / `deploy --ui` / `--port`）→ moonflux 已有面（spec 渲染器编辑器、editor-kernel、`core/pipeline` 编译结果、`serve --ws` 同端口、CLI 观测命令）→ 概念对照表 → 三阶段提案（只读拓扑视图 / 活指标叠加 / 诚实版状态视图）→ 非目标（不做 state 对象与跨服务状态引用、不做 SQL 控制台、不新增端口或命令语义、不让图反向定义 spec、不做像素级 UI 门禁）。

**Why a doc and not code**: 用户要求的是"探索"；且提案的每一阶段都要先决定"真相来源在哪"（`core/pipeline` 编译结果、既有客户端命令、压实/floor 报告），否则会变成照抄 SDF 的 state 表——那与本项目的"日志是唯一持久真相"冲突。

**Blocked by**: 无（与 T103/T104 并行）。

**Status**: ✅ 2026-10-10

**Checklist**:
- [x] Studio 事实逐条标注来源（官方页面）
- [x] moonflux 已有能力逐条标注位置
- [x] 概念对照表（含 ⚠️ 语义差异与 ❌ 缺口）
- [x] 三阶段提案各带门禁形态（结构断言、不做像素断言）
- [x] 非目标与风险（BigInt/Bytes、解码次序、每节点一份拓扑、轮询成本）
