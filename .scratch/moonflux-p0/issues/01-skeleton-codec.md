# 01 — 工程骨架 + 内核 codec 原语

**What to build:** moonflux 的"一内核多后端"工程骨架立起来，并交付内核的第一组能力包：字节编解码原语（varint 读取器、CRC32、hex、字节读写助手）。完成标志：`moon build --target wasm-gc|js|native` 全过、内核包在 wasm 与 native 双后端测试通过、`moon info`/`moon fmt` 干净。这为后续所有 ticket 提供可编译的骨架与编解码地基。

**Blocked by:** None — can start immediately.

**Status:** done (2026-09-15)

- [x] `moon.mod`（name=moonflux）+ 目录 `core/`、`adapters/`、`apps/` 成立，依赖方向 core ← adapters ← apps（adapters 暂可为空包占位）
- [x] `core/codec` 包：ULEB128/ZigZag 读取器（基于 BytesView 游标，越界/超长返回 Result 错误）、CRC32（IEEE，查表实现）、hex 编解码、大端定宽读写助手
- [x] 单元测试：每个原语有往返测试 + 边界（截断、最大值、非法输入）用例；内核包在 `--target native` 与 `--target wasm-gc` 双后端 `moon test` 通过
- [x] `moon info` 生成 `.mbti` 且提交；`moon fmt` 无 diff
- [x] `.gitignore`（_build 等）与首次提交
