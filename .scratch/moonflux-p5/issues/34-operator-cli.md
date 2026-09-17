# 34 — 算子管理 CLI（对标 SmartModule 命令面雏形）

**What to build:** `operator list/verify/describe`：对一个真实 `.wasm` 制品做 ABI v1 校验（导出面、
版本、无导入段），列出可发现的内置算子，说明每个算子的 ABI 契约与预算档位。对标 CLI 规划里
"算子管理雏形"那一批（docs/cli-roadmap.md §3.2）。

**Blocked by:** 无（P2 的 ABI 与探针已就绪）。

**Status:** ✅ done (2026-09-17)

- [x] `operator verify <path.wasm>`：复用 `tools/probe_operator_exports.py` 的 WAT 真相源思路，
      但以**运行时**为准（同一个 wasmtime 宿主做实例化握手 + ABI 版本 + init 往返）
- [x] `operator describe <path.wasm>`：导出面、ABI 版本、预算档位默认值；失败时给出结构化原因
      （缺导出 / 版本不符 / 有 import 段）
- [x] `operator list`：仓库内可用的算子制品（identity/upper/fixture）与其能力摘要
- [x] 门禁：好算子通过、坏算子（有 import 段 / 缺导出 / ABI 版本不符）各自给出**可区分**的错误

## 落地记录

- **运行时即真相源**：`operator verify/describe` 走**生产宿主**（同一个 wasmtime 适配器、同一个
  ABI v1 握手、同一个 init 往返）——没有第二套"更宽松"的校验器能给出不同答案；`operator list`
  对每个制品做同样的握手并报告健康而非文件名。
- `describe` 的预算数字**直接取自 `core/operator` 的常量**（`max_records_per_call` / `fuel_per_call`），
  因此不可能与运行时执行的实际值漂移；门禁里 grep 这些数字作为漂移报警。
- 适配层新增 `fs.list_dir`（opendir/readdir → NUL 分隔缓冲 → MoonBit 拆分排序；排除 `.` 与 `..`）。
- 门禁：`scripts/e2e-p5-operator.sh` 4 条断言全绿（好算子通过、垃圾被拒且带解析原因、describe 的
  ABI 与预算、list 的逐模块健康）。
