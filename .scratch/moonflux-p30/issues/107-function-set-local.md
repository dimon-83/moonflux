# T107 · 函数集的本地创建路径（`--data-dir`）

**What to build**: `function-set create/get/list/delete` 接受 `--data-dir`，直接对本地元数据存储操作；`--remote` 与 `--data-dir` 同时给按名拒绝。**不允许第二套实现**：本地路径复用节点侧同一个 handler（`dispatch_function_set`），因此本地应答与服务器应答逐字节同源。

**Why**: 九条缺口里唯一的**纯产品缺口**——单机用户为了装一个资产必须先起一个 `serve`。不是设计限制，是命令面缺一条腿。

**Blocked by**: 无。

**Status**: ✅ 2026-10-10（决策 56）

**Checklist**:
- [x] `function_set_local_dir`（含互斥拒绝）+ `function_set_call`（本地/远端同一调用点，回复渲染共用）
- [x] 四个动词改为"先决定目的地，再渲染同一份回复"
- [x] `resolve_remote` 的缺参提示补上 `--data-dir`（多数命令都有本地口径）
- [x] 门禁 `scripts/e2e-p6-functions.sh` 第 11 条：本地 create/list/get/update/apply/run/delete 全通 + 互斥拒绝 + 删后 apply 失败
- [x] 案例 01 的步骤去掉 serve 绕法；user-guide 同时给出本地与远端口径
- [x] README 决策 56 / feature-matrix / roadmap / AGENTS P6 腿数（10 → 11）/ 缺口 8 状态
