# P30 · SDF 缺口追平·小票包（overview）

**Objective**（来自 `docs/sdf-gap-closure-plan.md` §3）：把九条缺口里"一票一个"的四项补齐，互不依赖。

**Scope**:
- T106 ✅ 连接器/外部数据案例（缺口 9 的案例部分）：`examples/sdf/09–11` + 门禁 `scripts/e2e-p30-connector-examples.sh`
- T107（未开始）函数集本地创建路径（缺口 8）
- T108（未开始）表达式静态检查探针（缺口 4：`fromJSON(value)` 被 `"a"` 占位符误杀）
- T109（未开始）轮询式 HTTP 源（缺口 9 的 `interval_ms`）

**Non-goals**：状态与窗口（P32，须先出 ABI v3 设计稿）、多汇（P33）、callout（须先选确定性边）、SQL/组件模型/Rust 工具链（不做）。
