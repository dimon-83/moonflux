# 34 — 算子管理 CLI（对标 SmartModule 命令面雏形）

**What to build:** `operator list/verify/describe`：对一个真实 `.wasm` 制品做 ABI v1 校验（导出面、
版本、无导入段），列出可发现的内置算子，说明每个算子的 ABI 契约与预算档位。对标 CLI 规划里
"算子管理雏形"那一批（docs/cli-roadmap.md §3.2）。

**Blocked by:** 无（P2 的 ABI 与探针已就绪）。

**Status:** ready-for-agent

- [ ] `operator verify <path.wasm>`：复用 `tools/probe_operator_exports.py` 的 WAT 真相源思路，
      但以**运行时**为准（同一个 wasmtime 宿主做实例化握手 + ABI 版本 + init 往返）
- [ ] `operator describe <path.wasm>`：导出面、ABI 版本、预算档位默认值；失败时给出结构化原因
      （缺导出 / 版本不符 / 有 import 段）
- [ ] `operator list`：仓库内可用的算子制品（identity/upper/fixture）与其能力摘要
- [ ] 门禁：好算子通过、坏算子（有 import 段 / 缺导出 / ABI 版本不符）各自给出**可区分**的错误
