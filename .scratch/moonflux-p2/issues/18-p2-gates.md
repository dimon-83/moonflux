# 18 — P2 门禁验证 + 文档同步

**What to build:** 汇总 P2 门禁（算子语义对拍一致）证据；文档同步；全量回归。

**Blocked by:** 17.

**Status:** ready-for-agent

- [ ] 门禁证据：scripts/crosscheck-operators.sh 全绿（native vs wasm 字节级一致）
- [ ] 回归：五个既有门禁脚本全绿；native+wasm-gc 测试；四后端矩阵
- [ ] README/AGENTS P2 状态 + 决策记录（wasmtime 选型依据、ABI v1 定稿、WASI-stub 策略）
- [ ] compatibility-matrix 增补算子沙箱条目；tickets 关闭
