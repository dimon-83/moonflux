# 96 — 标量变换接线 + 门禁 + 文档

**What to build:** 把 v2 标量调用接进数据路径与门禁体系。

- [x] spec：transform 增 `{"type":"scalar","function":"tax"}`（设计稿 §6 的"不立新字段"
    在触发条件下解除——引用面沿用函数名的精神不变，字段是**类型**不是函数列表）
- [x] 节点注册表：`scalar-functions.json`（name → module/tier/max_calls）+ apply 期解析
    （名字未注册 = apply 失败，带原因）；文件带 revision，apply 记录
- [x] transform 链：逐记录 eval（@ast.Value ↔ JSON 编解码在宿主侧），fail-closed
- [x] 门禁 `scripts/e2e-p26-scalar.sh`（6 腿）：
    1. scalar 变换跑通（tax 计算正确、shout 字符串变换）
    2. **对拍**：同一批数据，wasm 标量 fn 与等价 mbel 表达式输出逐字节一致
    3. fuel 超限 → 结构化 BudgetExceeded，无半批落盘
    4. 类型不匹配（tax 收到 string）→ 结构化拒绝且服务存活
    5. v1-only 模块照常工作（无 v2 导出 → scalar_eval 缺失 → 引用即 apply 失败）
    6. 重放确定性：同输入两次运行输出逐字节一致
- [x] gates.sh 加步（42 → 43）
- [x] 文档：设计稿「落地实录」+ 开放问题结论回填；AGENTS P26 行 + §8.1 补纪律；
    README 决策 50；feature-matrix 60 行转 ✅；user-guide；roadmap + 看板

**Status:** done (2026-09-25)
