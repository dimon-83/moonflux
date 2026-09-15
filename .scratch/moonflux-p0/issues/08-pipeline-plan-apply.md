# 08 — pipeline plan/apply/run + P0′ 端到端

**What to build:** CLI 增加 `pipeline plan|apply|run`：`plan` 把 spec 编译为进程拓扑（broker / source-runner / sink-runner 三个进程条目及各自配置）并与已应用拓扑（data-dir 下的 topology.json）做差异预览（+新增 / ~更新 / -删除，含字段级说明）；`apply` 校验后写拓扑清单；`run` 按拓扑在单进程内顺序执行：文件 Source → produce 到 topic 日志 → consume → stdout Sink（复用 05 的执行件）。P0′ 门禁：一份 spec 编译为可运行拓扑 + plan 差异预览可复现。

**Blocked by:** 05, 07.

**Status:** done (2026-09-15)

- [x] `core/pipeline` 包：`compile(spec) -> Topology`（纯计算，全后端可编译）；Topology/Process 模型含角色与配置快照
- [x] `plan`：拓扑 diff（增/改/删，字段级）人类可读输出；无已应用拓扑时显示全量新增
- [x] `apply`：写 `<data-dir>/topology.json`（含 spec 快照与编译时间注入的 Clock——测试注入固定时钟，内核红线不碰系统时钟）
- [x] `run --name N`：读已应用拓扑执行（或 `--spec` 直跑）；输出与 05 的 consume 格式一致
- [x] `scripts/e2e-p0p.sh`：写 spec → plan（空→新增 diff）→ apply → 改 spec（换源文件）再 plan（显示更新 diff）→ apply → run → diff 断言输出 = 源文件内容行
- [x] 双后端编译矩阵不回退（core 新包 wasm-gc + native 测试通过）
