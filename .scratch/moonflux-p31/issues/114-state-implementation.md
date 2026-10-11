# T114 · 状态与窗口实现（ABI v3）

**What to build**（按 `docs/operator-abi-v3-state.md` §8 的四步）：
1. ✅ **信封状态段 + SDK + 探针 v3 成对检查**（不接线）：`core/operator` 的 `StateEntry` / `encode_state_payload` / `decode_state_payload`（uleb 前缀 + v1 帧到payload尾）；SDK 的 `GuestStatefulOperator` + `run_stateful`；探针的 `STATE_EXPECTED` 成对规则；C 头声明 v3 两个导出。
2. ✅ **已完成（2026-10-11）**：`spec.state` 解析（含"状态主题≠数据主题"环校验与四态拒绝）、`apps/cli/state.mbt`（重放建视图、批后写回、UTF-8 键契约、上限**写前**拒绝）、`CompiledNode::Stateful` 与链上执行、`pipeline run` 开视图 / serve 取数路径传 `None`（按名拒绝）、`apps/operator-wordkeys`（SDF assign-key 的对应物）；门禁 `scripts/e2e-p31-state.sh` **8 腿全绿**并进入 `gates.sh`（46 → 47）。适配器 v3 链路 ✅（C 垫片 `mf_we_state_version`/`mf_we_state_apply` + FFI + `OperatorInstance.has_state`/`process_state` + 真 wasmtime 测试含状态接力与两条拒绝）；`apps/operator-counter` ✅（每键一次写回，去重）；⏳ 宿主视图与写回 + `spec.state` + **设置 key 的算子**。
3. ✅ **已完成（2026-10-11，决策 61）**：窗口**不做 watermark，做键的形状**——`apps/operator-tumble` 把 key 改写成 `key@窗口起点`（`window_ms` + `time_field`/`key_field`，事件时间可来自 event-time 列或值里的 JSON），窗口因此复用键控状态；门禁腿 9–10（窗口隔离、只随数据推进）。**如实边界**：无 idle 触发器、无自动过期、不读时钟；hopping/watermark 未立项。
4. **进行中**：腿 11 以"复制状态主题即可复现视图"落地（单机状态没有第二份持久真相；跨节点状态迁移未立项）。**示例移植进行中（3/8）**：`15-word-counter`、`16-word-probe`（跨管道共享状态主题）、`17-bank-processing`（参考样本原样 + debit/credit 拆分 + 透支选流）已入册（p29 15 → 22 腿、14 → 17 应用）；余下 `helsinki-transit`/`unreal-engine-analytics`/`car-processing`/`ny-transit`，其中 `car-processing` 的"超速"选流需要**结构化 JSON 谓词算子**（新列缺口 10）。

**Blocked by**: 无。

**Status**: Slice A ✅、Slice B ✅、Slice C ✅（2026-10-11，决策 61）；Slice D 单机口径 ✅（腿 11），跨节点状态迁移未立项；余下是把 8 个 stateful dataflow 逐个移植

**Checklist（Slice A）**:
- [x] `core/operator`：`STATE_ABI_VERSION` / 两个导出常量 / `StateEntry` / v3 信封编解码（含空状态、空记录、截断前缀、离谱计数、缺帧、v1 载荷误喂等 4 条 wbtest；13/13）
- [x] `apps/operator-sdk`：`GuestStatefulOperator` + `state_abi_version()` + `run_stateful()`（复用同一 buffered 槽位；3 条 wbtest 含"两次调用状态接力"与"畸形载荷不叫 guest"；10/10）
- [x] 探针：`STATE_EXPECTED` 成对检查（只出一个 = 红）+ 头部校验纳入 v3 名字；实测 `operator ABI surface OK (modules + published header)`
- [x] C 头声明 v3 两个导出与 v3 载荷布局（前缀 + v1 帧）
- [x] v1/v2 回归：既有模块与探针全绿
