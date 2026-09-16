# 15 — wasmtime 宿主适配层

**What to build:** `adapters/wasmtime-native`：经 wasmtime C API（FFI + native-stub）实例化
guest 算子模块、读写线性内存、调用 ABI 导出函数；接入 core/operator 的 OperatorEngine
接口。含 wasmtime 的获取与链接方式（brew/发布件 + `cc-link-flags`），以及 WASI import
的 stub 策略（算子不应有 IO）。

**Blocked by:** 14.

**Status:** ready-for-agent

- [ ] wasmtime 动态库获取与链接验证（本机 brew 48.0.2 已确认可装；记录可复现的链接配置）
- [ ] FFI 面：engine/module/instance/linker、memory read/write、exported func call
      （#borrow 标注全合规）；错误映射为结构化 WasmError（含 trap 消息）
- [ ] WASI stub：fd_write 等被 import 时不挂接实现 → 实例化失败即拒绝该模块（算子红线：无 IO）
- [ ] `Bytes` (ptr,len) 边界往返验证：宿主写入输入 → 调 process → 读出输出（含二进制安全）
- [ ] 集成测试（native）：透传算子、大小写转换算子、超预算中断；双后端矩阵不回退
