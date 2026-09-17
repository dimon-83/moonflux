# 36 — 函数集资产与命令面

**What to build:** 把 mbel 的表达式体自定义函数做成**版本化规则资产**：元数据存储新增
function_sets，CLI 命令面（create/list/get/delete），协议加法命令；校验含 mbel 标识符规则
与**确定性纯度检查**（拒绝 `now` 等时钟内建——AGENTS §5 重放红线）。

**Blocked by:** None.

**Status:** done (2026-09-17)

- [x] `apps/cli/metadata.mbt`：`FunctionDef{name, params, body, description?}`、
      `FunctionSet{name, version, functions[]}`；`create/delete/list/get`（版本单调、重名拒绝、
      原子写沿用 MetadataStore）
- [x] 校验（**分两层，见 §评估校核**）：资产级 = 标识符规则（非关键字/非聚合/非 `$env`、
      集合内唯一）、params 唯一、body 非空、未知字段拒绝、纯度（`now` 拒绝，文本级 token 扫描）；
      被引用闭包 = 名字/类型检查由 mbel 静态检查承担（**参数无类型声明，按调用点推断**，
      故“整集合类型校验”不可得，不得承诺）
- [x] `apps/transform`：错误文本截断（≤512 字符 + 标记）——深递归错误消息实测 ~4.4 KB/次，
      逐记录失败会放大（见 §评估校核 #4）
- [x] 协议：`CMD_FUNCTION_SET_CREATE/LIST/GET/DELETE = 22/23/24/25`（加法式，载荷 JSON）
- [x] CLI：`function-set create --name N --file fns.json --remote <node>` / `list` / `get` / `delete`
- [x] `serve`/`spu`/`sc` 接命令（函数集为**节点本地资产**，逐节点部署与现行逐节点 apply 一致）
- [x] 单测：版本单调、重名/坏名/纯度拒绝不落脏、存储往返

## 评估校核（2026-09-16，mbel 0.3.3 探针实测）

> 本机探针全部以 `apps/transform` 白盒测试跑通后回填，探针文件已删；结论均已固化为
> `apps/transform/transform_wbtest.mbt` 的用例（native / wasm-gc 16/16 通过）。

| # | 观测（命令/表达式 → 结果） | 对设计的影响 |
| :--- | :--- | :--- |
| 1 | `shout(value)`，body `upper(x) + "!"`，记录 `abc` → `ABC!` | 注册先于静态检查 → 自定义名发布期可解析、运行期一致 ✅ |
| 2 | `boom(value)`，body `x / 0` → **发布期**拒绝 `invalid operation: string / int` | 类型错误按**调用点实参类型**推断并拦截（参数无类型声明） |
| 3 | 集合含坏函数但表达式不引用（`upper(value)` + `x / 0`）→ **通过** | 校验是「被引用闭包」而非「整资产」→ 承诺降级（见 checklist 修订） |
| 4 | `ping(100000)`（字面量深递归）→ 发布期拒绝；错误文本 4417 字符 | 256 层上限在发布期生效；**错误文本 ~4.4 KB**，逐记录失败会放大 → 需截断/限速 |
| 5 | 数据驱动深递归 `upper(value) + string(ping(headers_count))` + 300 头记录 → 运行期 `Err` | 检查期看到 `headers_count=0` 终止 → 运行期 fail-closed ✅（错误文本 4409 字符） |
| 6 | 顶层 `value == "a" ? "yes" : "no"` 编译通过；顶层 `if value == "a" { … }` → **Vm compile 拒绝**；`if` 仅函数体内可用 | 生产语法面 = 三元；`if {}` 是检查引擎/函数体构造 → 文档与门禁按 `?:` 写 |
| 7 | 内建表（`builtin/*.mbt` 注册名）：abs bitand bitnand bitor bitshl bitshr bitushr bitxor concat date duration first flatten floor get int join keys last len lower max mean median min now repeat replace reverse round sort split string take timezone trim type uniq upper values | 无 `str`/`substr`；转换用 `string()`/`int()`/`floor()`；`concat` 面向数组 |
| 8 | `builtin/time.mbt`：`now` 读宿主时钟；`date`/`duration` 为字符串解析；`timezone` 仅接受 `UTC`/`""` | 纯度黑名单 `["now"]` **充分且必要**；文本扫描仅误拒串字面量中的 `now`（fail-closed 方向） |
| 9 | `x + len(x) / (len(x) - 1)` 对 len=1 记录 → `aInfinity`（`/` 为浮点，除零不报错） | 数值边界**不会自然报错** → 函数参数按字符串语义用，算术留在调用点（字段类型已知处）；呼应 T39「带类型参数」 |

**结论：方案维持（go）**，三处修正已并入上方 checklist 与 T37/T38：
① 全量集合类型校验不可得 → 资产级=语法+纯度，类型=被引用闭包；
② 错误文本必须有界（截断 + 失败记录限速）；
③ 顶层语法以 `?:` 为准，`if {}` 仅在函数体内可用。

### 关账（2026-09-17）

落地：`apps/cli/metadata.mbt`（`ClusterMetadataFunction`/`ClusterMetadataFunctionSet` + 资产文档
编解码 + `validate_function_set` + create/get/list/delete，create 即 upsert 并报告 deployed/updated）、
`apps/transform`（`RuleFunction` + `validate_functions` + `compile_with` + `MAX_ERROR_CHARS` 截断）、
协议 22–25（`core/client/protocol.mbt`）、CLI 四动词（`apps/cli/function_set.mbt`）、
三个分发点（`serve` hub 路径 / `serve` WS 会话 / `sc`·`spu` 控制连接）、单测 6 条（`metadata_wbtest.mbt`）。

**两处与计划的差异（留痕）**：
1. 决策编号用 README 实际序号 **27/28**（计划里写的 30/31 是按中途决策数估的，README 现止于 26）。
2. `apps/transform` 暴露 `RuleFunction` 而非直接吃 mbel 的 `UserFunctionDef`：mbel 类型不出 apps/transform，
   `apps/cli` 不依赖 mbel（分层纪律）。

**顺带修复**：`node.mbt` 三处 HELLO 把*帧*版本号（`PROTOCOL_VERSION=2`）当*协议主版本*发出——
`sc`/`spu` 不校验所以一直没暴露，`serve` 校验（P4 起）直接拒绝，本票的 CLI 路径撞上后修复为 `encode_hello(1, 0)`。