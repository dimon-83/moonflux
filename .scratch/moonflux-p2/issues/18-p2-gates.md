# 18 — P2 门禁验证 + 文档同步

**What to build:** 汇总 P2 门禁（算子语义对拍一致）证据；文档同步；全量回归。

**Blocked by:** 17.

**Status:** ✅ done (2026-09-16)

- [x] 门禁证据：`scripts/crosscheck-operators.sh` 全绿（native vs wasm 字节级一致）
- [x] 回归：六个既有门禁脚本全绿；native+wasm-gc 测试；四后端矩阵
- [x] README/AGENTS P2 状态 + 决策记录（wasmtime 选型依据、ABI v1 定稿、WASI-stub 策略）
- [x] compatibility-matrix 增补算子沙箱条目；tickets 关闭

## P2 门禁证据（2026-09-16 全绿）

| 检查 | 命令 | 结果 |
| :--- | :--- | :--- |
| **算子语义对拍（门禁本体）** | `scripts/crosscheck-operators.sh` | 9 腿全绿：upper/identity 的 mbel-vs-wasm 字节一致、config 注入控制组、refuse/坏 config/trap/spin fail-closed、serve 路径同链同输出、golden 生成器 `--check` |
| 算子构建门禁 | `scripts/build-operators.sh` | 三算子（identity/upper/fixture）产出 + `tools/probe_operator_exports.py` 以 WAT 断言 7 导出面 |
| 回归：既有门禁 | `crosscheck-protocol` / `e2e-p0` / `e2e-p0p` / `e2e-p1-connectors` / `e2e-p1-rules` | 5/5 全绿 |
| 单元/集成测试 | `moon test --target native` / `--target wasm-gc` | 103/103、76/76 |
| 四后端编译矩阵 | `moon build --target wasm\|wasm-gc\|js\|native` | 4/4，0 error |
| 生成物一致性 | `tools/gen_{spec_corpus,protocol_vectors,operator_golden}.py --check` | 全部 up to date（且 `moon fmt` 对生成文件为 no-op） |

## 与计划的偏离（如实记录）

- **ticket 15 的 blocker 定性更正**：所谓"wasmtime 后台编译 panic"实为 shim 类型镜像
  尺寸错位导致的内存踩坏（见 15 号 ticket 的更正说明）。上游无 bug，也不需要
  wasm-tools reduce / 子进程宿主 / moonrun 这三条解锁路径——它们仅作为备选记录保留。
- **spec 的 `export` 字段未实现**（有意）：ABI v1 导出名固定，开放该字段只会诱使作者偏离契约。
- **新增 `config` 字段**（ticket 外）：ABI 早已承诺 `mf_op_init(config)`，但宿主此前一律送 `{}`；
  P2 把它打通（spec `config` 对象 → guest），否则"算子可配置"只是纸面能力。
- **宿主墙钟超时未接线**：`call_timeout_hint_ms` 已发布，但 adapter 目前不读时钟（内核红线同源）；
  实际治理靠记录数 + fuel 双预算。矩阵第 14 条标为 ⚠️ 部分并注明缺口，不谎报为已完成。

## P2 交付物索引

| 交付物 | 位置 |
| :--- | :--- |
| 内核侧 ABI / 预算 / 信封 | `core/operator`（`ABI_VERSION`、`BudgetTier`、`fuel_per_call`、信封编解码、注入式 `OperatorEngine`） |
| 宿主适配层 | `adapters/wasmtime-native`（`wasmtime_shim.c` + `wasmtime.mbt` + `ffi.mbt`） |
| guest SDK | `apps/operator-sdk`（`GuestOperator` 契约、缓冲调用协议、config 解析、identity/uppercase 参考实现） |
| 示例算子与夹具 | `apps/operator-identity`、`apps/operator-upper`、`apps/operator-fixture`（identity/refuse/trap/spin） |
| 消费路径接入 | `apps/cli/rules.mbt`（`CompiledNode`：mbel 逐条 + wasm 逐批）、`serve.mbt`、`pipeline.mbt` |
| 门禁与工具 | `scripts/crosscheck-operators.sh`、`scripts/build-operators.sh`、`tools/probe_operator_exports.py`、`tools/gen_operator_golden.py`、`tools/moonbit_fmt.py` |
| 取证文档 | `docs/p2-wasm-host-spike.md`（含 T15 类型尺寸取证） |
