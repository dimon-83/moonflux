# T111 · 正则基础能力（`primitives/regex`）

**What to build**:
1. `core/regex`：纯 MoonBit 引擎（无 IO/时钟/依赖，全后端），**Thompson NFA 模拟**（线性、无回溯爆炸）。子集：字面量、`.`、`*`/`+`/`?`/`{n}`/`{n,m}`、字符类（含范围与取反）、`^`/`$`（**字符串锚**，无多行）、分组与 `|`、`\d\w\s\D\W\S` 与转义元字符；**按名拒绝**：`\b`、反向引用、环视、命名组、内联 flag、懒惰/占有量词、Unicode 类。
2. spec 变换 `{"type":"regex","pattern":P}`（可选 `"invert":true`）——**apply 期编译**，不支持的构造按名拒绝。
3. 执行面 `apps/cli/rules.mbt` 的链上加 `Regex` 节点（过滤 = 更短的批，与沙箱算子同形状）。
4. 案例 14（`examples/sdf/14-regex-genz`）：SDF `primitives/regex` 的样例数据与模式，正例/取反/不支持构造三件套。
5. 门禁：`scripts/e2e-p29-examples.sh` 腿 13–15；引擎自身的 wbtest 表；后端矩阵。

**Blocked by**: 无（引擎是纯计算，不需要 ABI/宿主改动）。

**Status**: ✅ 2026-10-10（决策 59）

**Checklist**:
- [x] spec `RegexTransform(pattern, invert)` + 解析（空 pattern 拒绝、invert 类型校验、未知键拒绝、未知类型提示含 regex）
- [x] `CompiledNode::Regex` + apply 期编译 + 链上过滤（fail-closed 结构化拒绝）
- [x] 案例 14 夹具 + README（子集与拒绝边界写清）
- [x] 门禁腿 13–15 + examples 索引 + feature-matrix/user-guide/port/plan
- [x] `core/regex` 引擎 + wbtest（9 条：子集/锚/类/分组/量词/SDF 模式/线性模拟/全部拒绝/畸形模式）
- [x] 四后端编译 OK；native 302 / wasm-gc 199 全绿
- [x] 门禁 `e2e-p29-examples.sh` 15 腿绿；决策 59；文档全部同步
