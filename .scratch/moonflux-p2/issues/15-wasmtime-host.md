# 15 — wasmtime 宿主适配层

**What to build:** `adapters/wasmtime-native`：经 wasmtime C API（FFI + native-stub）实例化
guest 算子模块、读写线性内存、调用 ABI 导出函数；接入 core/operator 的 OperatorEngine
接口。含 wasmtime 的获取与链接方式（brew/发布件 + `cc-link-flags`），以及 WASI import
的 stub 策略（算子不应有 IO）。

**Blocked by:** 14.

**Status:** ✅ done (2026-09-16) — 集成已解锁：根因是 shim 的手写类型镜像尺寸
（`wasmtime_val_t` 真实 32B / 镜像 16B、`wasmtime_memory_t` 真实 24B / 镜像 16B，后者在
`instance_export_get("memory")` 时踩坏相邻 func 句柄）→ 改为直接使用真实 `wasmtime.h` 类型后
3/3 集成绿。**注意**：当时的"后台编译 panic"是**误导性症状**（内存踩坏后的二级表现），
不是上游 bug；下述取证链保留为排查记录。

> **取证链（T15 probe，/tmp/t15probe + tools 内探针脚本）**
> 1. `wasmtime run` CLI 跑同一模块：✅ exit=0（模块合法）。
> 2. 独立 clang 探针（直链 wasmtime、真头文件、主线程）：✅ 全阶段绿——C API 调用序列、
>    `Bytes` 边界、缓冲协议全部可行。
> 3. 独立 clang 探针（worker 线程）：✅ 绿——线程因素排除。
> 4. 生产 shim（clang 编译）+ 独立 main：⚠️ 后台线程 panic（vmoffsets
>    num_defined_memories 断言），但主线程全阶段绿、exit=0——**panic 不致命**。
> 5. moon-test 进程（MoonBit 运行时共存）：同样的后台 panic → 进程 abort（测试失败）。
>
> **结论**：wasmtime 48 的某条后台编译/compilation 路径对 MoonBit 生成的模块 panic
> （并行编译已关仍复现 → 疑似 tier-up 或 GC-support 编译路径，见 shim 内 config）；
> 独立进程中该 panic 可存活，但 MoonBit 测试运行时共存环境下变为致命 abort。
> 已实施缓解：parallel_compilation off + gc_support off（未根除）。
>
> **解锁路径（按优先级）**：(a) 最小化模块（wasm-tools reduce）定位致断言的代码段并报
> 上游；(b) 子进程/独立宿主进程方案（探针已证可行，功能等价，性能后置）；(c) moonrun
> 作为宿主进程。集成测试停在 `wasmtime_integration_test.mbt.disabled`（恢复：改回
> `.wbt.mbt` 后缀；注意会让 `moon test --target native` 失败直至 blocker 解除）。

- [x] wasmtime 动态库获取与链接验证（本机 brew 48.0.2 已确认可装；记录可复现的链接配置）
- [x] FFI 面：engine/module/instance/linker、memory read/write、exported func call
      （#borrow 标注全合规）；错误映射为结构化 WasmError（含 trap 消息）
- [x] WASI stub：fd_write 等被 import 时不挂接实现 → 实例化失败即拒绝该模块（算子红线：无 IO）
- [x] `Bytes` (ptr,len) 边界往返验证：宿主写入输入 → 调 process → 读出输出（含二进制安全）
- [x] 集成测试（native）：透传算子、大小写转换算子、超预算中断；双后端矩阵不回退
      （6 项 in-process 集成：identity / upper / 缺失模块 / guest 拒绝 / trap / fuel 超限 / config 被拒）
