# P2 Spike：native 宿主执行 guest 算子 wasm 的路径

日期：2026-09-15 · 结论已由本地探针实证（非文献推断）· 决策记录见 README #14/#15/#16
（2026-09-16 补：T15 根因实录与落地形态，见文末两节）

## 问题

P2 门禁要求算子沙箱（对标 SmartModule）：guest 算子编译为 wasm，native 宿主进程内执行。
README 决策 2 已定「经典 core-wasm ABI 语义（线性内存 + i32 边界），不引入 WIT/组件模型」。
spike 要回答：**当前工具链能否产出宿主可调用的算子模块？宿主用什么运行时？**

## 实证结果（探针 `/tmp/wasmprobe`，moonc 0.10.2 + moon 0.1.20260629）

| # | 探针 | 结果 |
| :-- | :--- | :--- |
| 1 | `moon build --target wasm`（main 包） | 产物 = WASI command：导出仅 `memory` + `_start`，import `wasi_snapshot_preview1.fd_write` |
| 2 | `link.wasm.exports` + **非 pub** 函数 | 导出配置静默不生效（仅 memory/_start） |
| 3 | `link.wasm.exports` + **pub** 函数（Int 参数） | ✅ `abi_process` 以 func 导出，签名 `(i32, i32) -> i32` |
| 4 | **pub** 函数带 `Bytes` 参数 | ✅ 导出为 `(i32, i32) -> i32` —— **Bytes 跨边界就是 (ptr, len) 两个 i32** |
| 5 | 库包 `link: true`（foreign library 形态） | 产物 102 字节空壳、零导出（此路不通；且文档宣称的 `pkgtype(kind: "foreign_library")` 语法本版本 moon.pkg 不接受） |

**结论**：经典 ABI 路线在本工具链**可行**。算子模块 = 一个 `--target wasm` 的 main 型包，
ABI 函数用自然 MoonBit 签名书写（`Bytes` 进出即 (ptr, len)），通过 `link.wasm.exports` 显式导出；
模块自带的导出 `memory` 供宿主写入输入/读取输出。无需地址提取黑科技，无需等待工具链升级。

## 宿主运行时选型（建议 + 依据）

| 方案 | 评估 | 建议 |
| :--- | :--- | :--- |
| **A. wasmtime C API FFI**（`adapters/wasmtime-native`） | 成熟稳定；brew 可装（48.0.2）；C API 覆盖 实例化/内存读写/函数调用；adapters 层允许平台依赖（内核红线不涉及） | **采用**。风险最低、语义最完整；符合「adapters 承载平台依赖」的架构分工 |
| B. 纯 MoonBit 自研 wasm 解释器 | 完全可控、零外部依赖；但工程量大（子集也需数周），且 guest 模块由自家编译器生成、指令集可预知 | 备选。仅当 wasmtime 集成被证明不可行时启动 |
| C. 进程外 wasmtime CLI（stdin/stdout 传数据） | 实现最快；但每记录进程开销不可接受 | 否（仅可用于对拍工具） |

## ABI 草案 v1（T15 落地时定稿）

- 模块约定导出：`memory`（编译器自带）、`mf_op_init(config : Bytes) -> Int`、
  `mf_op_process(input : Bytes) -> Bytes`（Bytes = (ptr, len) i32 对）；
- 载荷 = 线协议 RecordBatch 帧（复用 core/protocol，段文件即协议流的对偶：算子输入输出也是协议流）；
- 版本化：帧头已有 version 字段；ABI 层再加 `mf_op_abi_version() -> Int`；
- 预算治理：宿主侧（wasmtime epoch/fuel 或调用前后墙钟）+ 每批记录数上限（复用 P1 budget 分级经验）；
- 结果表示（T15 首项验证）：`Bytes` 返回值在导出边界的表示（预期同为 (ptr, len)，宿主从 guest memory 拷出）。

## 风险与跟进

- wasmtime 动态库的分发/链接（本仓库最终以 **dlopen 运行时解析符号**落地，见下文「T15 落地实录」）；
- guest 模块里 WASI import（fd_write）在 wasmtime 中需显式关停或 stub（算子不应有 IO）；
- `moon upgrade` 到含 `pkgtype` 语法的新工具链可简化导出声明，但需一次全仓兼容性回归——另行立项，不阻塞 P2。

## T15 落地实录（2026-09-16）：两个类型镜像尺寸

集成期出现的症状是**误导性的**：`wasmtime_func_call` 报出 `vmoffsets
num_defined_memories` 断言 panic，看起来像上游 wasmtime 的后台编译路径有 bug
（当时据此写了"上游 panic"的结论、并列出 wasm-tools reduce / 子进程宿主 / moonrun
三条解锁路径）。**实际根因在 shim 自己**：

| 类型 | 真实大小（arm64，wasmtime 48.0.2） | shim 早期镜像 | 后果 |
| :--- | :--- | :--- | :--- |
| `wasmtime_val_t` | **32 B** | 16 B | 每次调用结果写越 16 B 栈 |
| `wasmtime_memory_t` | **24 B** | 16 B | `instance_export_get("memory")` 覆盖 session 结构里相邻的 func 句柄 |

句柄被踩坏后，后续调用自然指向垃圾内存，于是表现为"上游神秘的 vmoffsets 断言"。
**修法**：shim 不再手写镜像类型，直接 `#include <wasmtime.h>` 用真类型，所有函数仍走
`dlsym`（保持零链接期依赖）。修后 3/3 集成绿，无需上述三条解锁路径（它们仅作为将来
真遇到上游问题时的备选记录）。

**留存的教训**：(1) 手写 FFI 镜像类型必须用 `sizeof` 探针钉死（`probe_sizes.c`）；
(2) 断言消息来自上游 ≠ 故障在上游——先验证自己传进去的内存布局。

## 落地形态（P2 定稿，供后续维护对照）

| 项 | 落地 |
| :--- | :--- |
| 引擎配置 | `parallel_compilation = false`（确定性）+ `consume_fuel = true`（预算可计量） |
| 库加载 | `dlopen`（默认 `/opt/homebrew/lib/libwasmtime.dylib`，`MOONFLUX_WASMTIME_LIB` 可覆盖）；**无链接期依赖** |
| 实例化 | 空导入实例化 ⇒ 有 import 段的模块直接被拒（算子无 IO 由结构保证） |
| 预算 | 启动送 `MF_STARTUP_FUEL`；每次 process 前装入 `core/operator.fuel_per_call(tier)`；耗尽 → `BudgetExceeded`（非裸 trap） |
| 配置 | `mf_op_init` 载荷 = spec 的 `config` 对象（原样透传，guest 自解析） |
