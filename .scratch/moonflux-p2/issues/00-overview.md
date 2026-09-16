# 00 — P2 里程碑概览（WASM 算子沙箱）

**门禁（可证伪）**
- 算子语义与参考实现（SmartModule）对拍一致。

**技术前提（已由 spike 实证，见 docs/p2-wasm-host-spike.md）**
- 当前工具链可产出宿主可调用的算子模块：pub ABI 函数 + `link.wasm.exports`；
  `Bytes` 跨导出边界 = (ptr, len) i32 对。
- 宿主运行时选型：wasmtime C API FFI（`adapters/wasmtime-native`）；纯 MoonBit 解释器为备选。

**Tickets（依赖序）**
- 14 ABI 信封与算子模块格式（纯内核/纯计算部分，无阻塞）
- 15 wasmtime 宿主适配层（blocked by 14）
- 16 guest SDK 与示例算子（blocked by 14）
- 17 端到端：算子接入数据路径 + 语义对拍（blocked by 15, 16）
- 18 P2 门禁验证 + 文档同步（blocked by 17）

**范围裁剪**：不做 WIT/组件模型（决策 2）；不做多算子链沙箱内编排（链式在宿主侧组合）；
wasmer/其它运行时不做。

**状态**
- [ ] 14 … [ ] 18
