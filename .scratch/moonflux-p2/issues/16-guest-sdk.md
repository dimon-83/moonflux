# 16 — guest SDK 与示例算子

**What to build:** 算子作者的 guest 侧：`apps/operator-guest`（`--target wasm` + link.wasm.exports
的模板包）暴露 mf_op_abi_version / mf_op_init / mf_op_process；至少两个真实算子：
透传（identity）与 to_uppercase；构建脚本产出 .wasm 制品并纳入版本管理或 CI 产物。

**Blocked by:** 14.

**Status:** ✅ done (2026-09-16)

- [x] guest 模板包：ABI 函数（pub + 整数/Bytes 签名）、配置解析（init 载荷 = JSON）
- [x] 示例算子：identity、to_uppercase（对拍 SmartModule 语义锚点）
- [x] `scripts/build-operators.sh`：确定性构建 .wasm（含 hash 输出，供宿主校验）
- [x] guest 侧单测（MoonBit 原生测试，语义先行）；导出面用探针脚本断言（exports/签名）
