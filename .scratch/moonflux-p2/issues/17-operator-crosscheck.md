# 17 — 算子接入数据路径 + 语义对拍

**What to build:** 把 wasm 算子接进消费路径（transform 链新增 `wasm` 类型，与 mbel expr 并列）；
建 P2 门禁的可证伪对拍：同一批 golden records 分别经 (a) MoonBit 原生实现 与
(b) wasm 算子执行，输出字节级一致；CLI `pipeline plan/run` 与 spec 校验同步扩展。

**Blocked by:** 15, 16.

**Status:** ✅ done (2026-09-16)

- [x] core/spec：transforms 项新增 `{ "type": "wasm", "module": "..." }`
      （校验 + 语料扩展）；core/pipeline compile 映射（capability 标记 wasm）
- [x] serve/run 的 transform 链支持 wasm 算子节点（预算与错误路径与 mbel 同策略：fail-closed）
- [x] 对拍框架：`scripts/crosscheck-operators.sh` —— identity 与 uppercase 算子
      native-vs-wasm 输出 diff 断言（golden records 数据文件真相源 + 生成器模式）
- [x] 集成测试：算子 trap → 结构化错误不吞记录；预算超限 → 明确报错

## 交付与偏离

- **spec 形态**：`{ "type": "wasm", "module": "<path>" }`，**没有** `export` 字段 —— ABI v1
  的 7 个导出名是固定的（core/operator 常量），暴露 `export` 只会诱使作者偏离契约。
  新增（ticket 外，但 ABI 早已承诺）：可选的 `config` 对象，作为 `mf_op_init(config)`
  的载荷；host 过去一律送 `{}`，等于把 ABI 的配置入口空转，现已打通并可端到端配置。
- **capability 标记**：`wasm`（非 `wasm-p2`）；`runnable()` 接受 `native | mbel | wasm`。
- **预算**：tier 的**记录数**上限（host 侧，已有）+ 新增 tier 的**指令数**（fuel）预算
  （`core/operator.fuel_per_call`，由 wasmtime adapter 每次调用前装入 store）。
  fuel 是确定性计量 —— 与内核"无系统时钟"红线一致，重放同一批数据得到同样的失败。
- **对拍门禁的 9 条腿**（`scripts/crosscheck-operators.sh`，全绿）：
  1. `upper`：mbel `upper(value)` vs `operator-upper.wasm` 字节一致（9 条 golden records）
  2. `identity`：wasm 透传 == 未变换的源流（空行由文本源规则丢弃，故基线用源流而非原始文件）
  3. fixture 控制组：config 注入的算子跑同一条链
  4. `refuse`：guest status ≠ 0 → 结构化错误带 guest 原文，且**不产生任何记录输出**
  5. 坏 config：init 阶段被算子拒绝 → 结构化错误
  6. `trap`：guest wasm trap → 结构化错误（含 backtrace 中的 abort 符号）
  7. `spin`：死循环被 fuel 预算拦下（0s），报 budget 错误
  8. `serve`：服务端消费路径跑同一条 wasm 链，输出与单进程 run 路径字节一致且确实被变换
  9. 生成器 `--check`：golden 数据文件是真相源，手改即失败
- **副产物（工具链）**：`tools/moonbit_fmt.py` —— 生成器按 `moon fmt` 的排版规则输出
  （80 列、超宽展开），因此 `moon fmt` 对生成文件是 no-op，`--check` 不再周期性假报 stale。
- 集成测试（in-process，`adapters/wasmtime-native/wasmtime_wbtest.mbt`）：identity/upper
  通过 wasmtime、缺失模块 → InvalidSpec、guest 拒绝 → GuestTrap、trap → GuestTrap、
  spin → BudgetExceeded、config 被拒 → InvalidSpec。native 103 / wasm-gc 76 全绿。
