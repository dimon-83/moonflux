# 算子作者指南（写一个 guest 算子）

> **定位**：回答"SDF 的 SmartModule/包，在 moonflux 里怎么写"——算子（guest 模块）的 ABI 面、三种形状、配置、构建自检与挂载，以及不可越过的纪律。**规约依据**：AGENTS.md §8.1（算子沙箱纪律）与 §1.1（MoonBit 语境四检）。**边界声明**：本文是作者面文档，**不新增任何语义**——ABI 与纪律的权威位置是 [`core/operator`](../core/operator/)（常量）与 [`tools/probe_operator_exports.py`](../tools/probe_operator_exports.py)（结构性事实的判官），本文只把两者讲清楚。
>
> **日期**：2026-10-10

## 0. 先看一句话

**一个算子 = 一个没有导入段的 wasm 模块 + 一组固定的导出。** 宿主把记录批交给它，它把记录批还回来；`1→0` 与 `1→N` 就是"还回来的批更短/更长"，没有特殊 API。

对应关系：SDF 的 `packages/*` 里那些 Rust SmartModule ≈ 这里的 guest 模块；SDF 的 `_hello-world_` 模板 ≈ [`apps/operator-identity`](../apps/operator-identity/)（最小、可编译、可挂载）。

## 1. 结构事实：guest 无导入

模块**不得有 import 段**——没有 WASI、没有时钟、没有随机源、没有 IO。这不是约定，而是宿主的纯函数假设所依赖的结构性事实，由构建门禁以编译器自己的 WAT 为真相源检查（`scripts/build-operators.sh` 的探针步骤）。想让算子读文件、调 HTTP、看时间——**那不属于算子**：IO 属于连接器与宿主侧变换，事件时间来自记录本身。

## 2. 最小算子：逐行读一个 hello world

```moonbit
// apps/operator-identity/operator.mbt（节选）
pub fn mf_op_abi_version() -> Int { @sdk.abi_version() }
pub fn mf_op_alloc_input(len : Int) -> Bytes { @sdk.alloc_input(len) }
pub fn mf_op_init(config : Bytes) -> Int {
  match @sdk.parse_config(config) { Ok(_) => 0; Err(_) => -1 }
}
pub fn mf_op_process(input : Bytes) -> Bytes {
  let _ = @sdk.run_buffered(@sdk.identity(), input)
  @sdk.buffered_output()
}
pub fn mf_op_output_len() -> Int { @sdk.output_len() }
```

- `mf_op_abi_version`：宿主先问版本，不匹配就拒绝（**不会**"尽力而为"地跑）。
- `mf_op_alloc_input`：宿主在你的线性内存里开一块地写输入（guest 拥有分配权）。
- `mf_op_init`：宿主把 spec 的 `config` **原样**（JSON 文本）交给你一次；返回非 0 即拒绝该变换。
- `mf_op_process`：批进批出。`@sdk.run_buffered` 负责信封的编解码与状态记录。
- `mf_op_output_len`：上一批答案的长度（答案的位置由 `mf_op_process` 的返回值给出）。
- 失败时 `mf_op_last_status` / `mf_op_last_error` 给出结构化原因（文本由宿主截断）。

完整契约（含缓冲协议的时序）写在发布头 [`apps/operator-sdk/include/moonflux_operator.h`](../apps/operator-sdk/include/moonflux_operator.h)。

## 3. 三种形状：照着现成的抄

| 形状 | 现成模块 | 关键点 |
| :--- | :--- | :--- |
| **1→1**（map） | `apps/operator-upper` | 逐条改值；key/timestamp/headers 原样带过 |
| **1→0**（filter） | `apps/operator-filter` | 丢弃 = 返回更短的批；`{"min_len":N}` / `{"contains":"s"}` 在 `mf_op_init` 校验 |
| **1→N**（flat-map） | `apps/operator-flatmap` | 扇出 = 返回更长的批；子记录继承源记录的 key/timestamp/headers |
| **逐值标量**（ABI v2） | `apps/operator-scalar` | 可选成对导出 `mf_op_scalar_abi_version` + `mf_op_eval`；由节点注册表按名绑定 |

写新算子时最省事的做法：复制一个形状相同的模块，改 `moon.pkg` 的包名与 `operator.mbt` 的算子体，在 `scripts/build-operators.sh` 的模块列表里加一行。

## 4. 配置：只走 `mf_op_init`

- 宿主**不解释** `config`：它的语义属于算子。因此**未知键应当拒绝**（返回 -1），否则"写错的配置静默生效"就成了这个算子的特性。
- 取配置用 SDK 的两个读取器：`@sdk.config_string(cfg, key)` 与 `@sdk.config_int(cfg, key)`。JSON 数字是 double，`config_int` 是唯一做类型化与**小数拒绝**的地方——`{"min_len": 10.5}` 会被拒，而不是被悄悄截成 10（`apps/operator-filter` 的实测行为）。
- 配置错误要在 `mf_op_init` 报错并在 `last_error` 里说清**哪个键**：拒绝发生在发布期，操作员才看得到。

## 5. 构建、自检、挂载

```bash
# 1) 构建（wasm = 经典 wasm，不是 wasi/组件模型）
moon build --target wasm

# 2) 探针自检：无导入段 + 导出面签名 + 成对规则 + 发布头一致性
scripts/build-operators.sh          # 构建全部模块并跑探针

# 3) 挂载：作为变换（批算子）
#    {"type":"wasm","module":"_build/wasm/debug/build/apps/operator-<x>/operator-<x>.wasm",
#     "config":{...}}
#    或作为标量函数（ABI v2，节点注册表 scalar-functions.json 按名绑定）
#    {"type":"scalar","function":"<注册名>","config":{...}}
```

算子的**语义变更必须有 native-vs-wasm 字节级对拍**（`scripts/crosscheck-operators.sh`）；测试向量放数据文件（`scripts/testdata/operator-golden.txt`，由 `tools/gen_operator_golden.py` 生成），手改即失败。

## 6. 纪律（违反即返工）

1. **无导入**：碰 IO/时钟/随机的想法先回到 §1。
2. **双预算**：记录数上限 + fuel（指令数）上限；超限报 `BudgetExceeded` 而不是裸 trap；**fuel 是确定性计量**，重放同批数据得同结果。
3. **墙钟只报告、不设门禁**：耗时只打印与告警，绝不做 pass/fail 判据（否则同一批数据在忙机器上会红）。
4. **fail-closed**：算子拒绝/trap/超预算都必须变成结构化错误，且**已产出的半批绝不落 Sink**。
5. **输出是字符串世界**：批算子的信封里是记录（key/value/时间戳/headers），规则层的表达式则**必须返回字符串**——这也是为什么"过滤"和"扇出"必须落在算子这一层（`docs/sdf-examples-port.md` 案例 02/04 的由来）。

## 7. 给非 MoonBit 作者：稳定 C ABI 头

[`include/moonflux_operator.h`](../apps/operator-sdk/include/moonflux_operator.h) 是完整的 C 面（v1 七个导出 + v2 可选成对 + 缓冲协议说明）。**任何能产出无导入 wasm 的语言**都可以照它写 guest——Rust、C、AssemblyScript 都行，仓库不为此引入任何依赖（作者的 guest 是用户代码，约束在"无导入"，不在语言）。头文件不会漂移：每次算子构建都校验它的导出名与 ABI 版本号与实现一致（漂移即红）。

## 8. 明确不做

- **WASI / wasm32-wasip2 / 组件模型（WIT）**：WASI 会带来导入段与 IO 能力，直接摧毁"纯函数"的结构性事实（AGENTS §9 明确列为不首期引入）。
- **仓库内提供 Rust 工具链**（`sdfg` 式 proc-macro、crates.io 解析）：那是把参考系统的工具链假设搬进来；要写 Rust guest，用你自己的工具链产出无导入 wasm 即可。
