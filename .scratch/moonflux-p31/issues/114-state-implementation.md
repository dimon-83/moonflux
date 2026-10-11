# T114 · 状态与窗口实现（ABI v3）

**What to build**（按 `docs/operator-abi-v3-state.md` §8 的四步）：
1. ✅ **信封状态段 + SDK + 探针 v3 成对检查**（不接线）：`core/operator` 的 `StateEntry` / `encode_state_payload` / `decode_state_payload`（uleb 前缀 + v1 帧到payload尾）；SDK 的 `GuestStatefulOperator` + `run_stateful`；探针的 `STATE_EXPECTED` 成对规则；C 头声明 v3 两个导出。
2. ⏳ 宿主视图与写回 + `spec.state` 解析 + 计数算子 + **设置 key 的算子**（设计稿补注要求）。
3. ⏳ 窗口助手（`key@窗口起点`、水位=已见最大事件时间）+ 迟到策略。
4. ⏳ 复制交互（两副本重放得同一视图）+ 用它们移植 8 个 stateful dataflow。

**Blocked by**: 无。

**Status**: Slice A ✅ 2026-10-10；其余待做

**Checklist（Slice A）**:
- [x] `core/operator`：`STATE_ABI_VERSION` / 两个导出常量 / `StateEntry` / v3 信封编解码（含空状态、空记录、截断前缀、离谱计数、缺帧、v1 载荷误喂等 4 条 wbtest；13/13）
- [x] `apps/operator-sdk`：`GuestStatefulOperator` + `state_abi_version()` + `run_stateful()`（复用同一 buffered 槽位；3 条 wbtest 含"两次调用状态接力"与"畸形载荷不叫 guest"；10/10）
- [x] 探针：`STATE_EXPECTED` 成对检查（只出一个 = 红）+ 头部校验纳入 v3 名字；实测 `operator ABI surface OK (modules + published header)`
- [x] C 头声明 v3 两个导出与 v3 载荷布局（前缀 + v1 帧）
- [x] v1/v2 回归：既有模块与探针全绿
