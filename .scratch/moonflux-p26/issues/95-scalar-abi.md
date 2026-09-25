# 95 — ABI v2 标量调用：内核协议 + 宿主调用路径 + guest SDK

**What to build:** 设计稿 `docs/operator-abi-v2-scalar.md` 落地（触发条件成立：用户提交的
标量函数需求 = 本轮用户指令）。v1 的 7 个批导出**一个不改**；新增可选导出：

- `mf_op_scalar_abi_version() -> i32`（缺失 = v1-only 模块，继续可用）
- `mf_op_eval(ptr, len) -> i64`（输出长度；`< 0` = 结构化错误码，文本走 last_error）

**开放问题的结论**（按设计稿维护规则，先答后做，答案回填设计稿）：

1. **编码**：JSON 文本（设计首版）——逐记录 parse/stringify 是热路径成本，**接受并以
   基准留痕**；二进制编码在量测显示必要时单独立项。
2. **批量化**：**不做**——与 v1 批边界重叠，且无量测支撑；请求是单函数单求值。
3. **错误分类**：最小分类码：`-1` = 求值错误（文本走 last_error），`-2` = 请求无法解码；
   fuel 超限**不是码**——它表现为 trap，由宿主映射为 `BudgetExceeded`（与 v1 同一映射）。
4. **注册表治理**：节点侧文件 `<data-dir>/scalar-functions.json`（name → module/tier/
   max_calls_per_batch），**apply 时解析绑定**（决策 27 的绑定纪律）；同名冲突拒绝；
   文件带 revision，apply 记录解析到的 revision。
5. **参数类型**：请求 args 自带 JSON 类型，guest 按注册的期望类型**显式校验**（与 mbel
   按调用点推断的差异写进文档）。
6. **mbel-in-guest**：不在本里程碑。

**Status:** done (2026-09-25)

- [x] `core/operator`：SCALAR_ABI_VERSION=1 + 导出名常量 + 请求/应答 JSON 编解码
      （@ast.Value 映射：Str/Num/Bool/Array ✓；Bytes/Object 遇即 EvalError——设计 §3）
- [x] 垫片：`mf_we_scalar_abi_version`（缺失导出 → 明确信号）+ `mf_we_scalar_eval`
      （每调用安装 fuel_per_call，与批预算分开）
- [x] 适配器：`OperatorInstance` 增可选 `scalar_eval`（有 v2 导出才有）
- [x] guest SDK：`register_scalar(name, fn)` + 两个 v2 导出实现（@json in-guest，无导入）
- [x] fixture guest：`apps/operator-scalar`（tax: num×num→num；shout: str→str）
- [x] 探针扩展：v2 导出同样无 import 段（WAT 真相源）
- [x] fail-closed：trap/拒绝/预算/编码错误 → 结构化 EvalError，记录不放行
