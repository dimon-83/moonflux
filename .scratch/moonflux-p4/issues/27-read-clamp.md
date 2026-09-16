# 27 — 读语义接线：COMMITTED 读

**What to build:** 把 `core/replica` 已实现并单测过的读钳制接到线协议上：客户端可以选择
按 **Committed**（≤ HW）或 **Uncommitted**（≤ LEO，默认）读，并在应答里拿到水位，从而知道
"我读到的是已复制前缀还是 leader 的全部"。

**Blocked by:** 无（P3 语义已就绪）。

**Status:** ✅ done (2026-09-17)

- [x] 协议：新增 `CMD_FETCH_COMMITTED`（应答 = 水位 + 原始帧，复用 T22 的 sync response 形态），
      既有 `FETCH` 保持字节兼容（默认 Uncommitted）
- [x] 服务端：`dispatch_fetch` 按模式取 leader 的水位并钳制；越界读 → 结构化拒绝（而非空结果）
- [x] 客户端 SDK：`Consumer` 增加模式参数；CLI `consume --committed`
- [x] 单测：钳制边界（正好在 HW 合法且空、越过 HW 拒绝）；E2E：leader 有未复制的尾巴时，
      Committed 读不到它、Uncommitted 读得到
- [x] 矩阵 #11 状态更新（客户端半边落地；消费组仍缺）

## 落地记录

- **协议选择：加法而非改版**。ticket 原话是"新增 `CMD_FETCH_COMMITTED` 且既有 FETCH 保持字节兼容"，
  落地时确认了这是对的：`CMD_FETCH_COMMITTED = 18` 的应答复用 T22 的 `SyncResponse` 形态
  （水位 + 原始帧），`FETCH` 的应答一个字节没动——**帧版本号是用来拦"不兼容变更"的**，这里没有
  不兼容，所以不升版本、也不需要所有对端同时升级。
- **服务端钳制**：`dispatch_fetch_committed` 先按 `core/replica.check_read` 判定（正好在水位上是
  合法且空、越过水位结构化拒绝），再把窗口夹到水位（leader 手里可能有更多，committed 读者看不到）。
  单节点 `serve` 的水位 = 日志末端（只有一个副本时已复制前缀就是全部），所以它两种模式等价——
  这是正确的语义而不是简化。
- **数据节点**：committed 读**必须问 leader**（只有它知道副本确认到哪），非 leader 的回答是
  `ERR_WRONG_ROLE` 并告知谁是 leader；读前先把 leader 自己的 LEO 折进账本（T22 的老坑）。
- **客户端与 CLI**：`Consumer::fetch_committed` 返回 `(entries, hw, leo)`；`consume --committed`
  把水位写到 **stderr**（stdout 保持纯记录流，按列可解析）。
- **顺带修正一处旧账**：CLI 的 `fail()` 此前把错误打到 **stdout**——与"stdout 是数据、stderr 是
  诊断"的约定相悖，也让 committed 读的拒绝理由跑错了流。现已改为 stderr（`warn()` 用新增的
  `mf_cli_eprint`）。既有门禁脚本都是 `2>&1` 合并读，故零回归（8 个脚本复跑全绿）。
- 门禁：`scripts/e2e-p4-readmodes.sh` 3 条断言全绿（健康时两模式一致 + 水位上报；副本死亡后
  Uncommitted 读到 4 条而 Committed 只给 2 条并报 `hw=2 leo=4`；水位处读合法且空、越水位拒绝）。
- 测试：`apps/client/client_wbtest.mbt` +2（committed 应答解码取 offset 自帧内 base、服务端拒绝
  被如实上报）。全量：native 150/150、wasm-gc 103/103。
- 矩阵 #11 更新（客户端半边落地；消费组/托管偏移仍缺）。
