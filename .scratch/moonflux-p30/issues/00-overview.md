# P30 · SDF 缺口追平·小票包（overview）

**Objective**（来自 `docs/sdf-gap-closure-plan.md` §3）：把九条缺口里"一票一个"的四项补齐，互不依赖。

**Scope**:
- T106 ✅ 连接器/外部数据案例（缺口 9 的案例部分）：`examples/sdf/09–11` + 门禁 `scripts/e2e-p30-connector-examples.sh`（6 腿）
- T107 ✅ 函数集本地创建路径（缺口 8）：`--data-dir`，与远端共用同一 handler（决策 56）
- T108 ✅ 表达式静态检查探针（缺口 4）：两个"表达式自己命名的形状"（决策 55）
- T109 ✅ 轮询式 HTTP 源（缺口 9 的 `interval_ms`）：轮询器永不说 `Exhausted`（决策 57）
- T110 ✅ 两个新案例：`12-custom-serialization`（三腿，含恒等往返）与 `13-parse-sentence`
- T111（未开始）`primitives/regex` 的基础能力（限定的正则子集）
- T112（未开始）算子作者指南 + 稳定 C ABI 头（缺口 5 的作者面）

**Non-goals**：状态与窗口（P32，须先出 ABI v3 设计稿）、多汇（P33）、callout（须先选确定性边）、SQL/组件模型/Rust 工具链（不做）。
