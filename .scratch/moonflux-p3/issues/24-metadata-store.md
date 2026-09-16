# 24 — 元数据存储（可插拔）+ 调和驱动 placement

**What to build:** 元数据的持久化与驱动：可插拔存储接口 + 本地文件后端（首个实现），SC 的
调和循环按 Spec（期望状态）与集群实况（实际状态）计算动作并落账；重启后状态可恢复。

**Blocked by:** 19、21。

**Status:** ✅ done (2026-09-16)

- [x] `MetadataStore` 接口（注入式函数字段）：`load() / save(state)`；本地后端 =
      `<data-dir>/meta/cluster.json`（原子写：临时文件 + rename）
- [x] SC 调和循环：读 Spec（声明式文件或 CLI 提交）→ `reconcile` → 执行可执行动作
      （分配 leader / 副本集合）→ 保存状态；**幂等**：无差异时不写、不发动作
- [x] 版本化：状态带单调版本号，写入冲突（并发 SC）报结构化错误（不做共识 —— 单 SC 假设显式声明）
- [x] CLI：`cluster status`（节点 / 分区 / leader / HW-LEO 一览）、`topic create -p N -r R`
      （对标命令面，见 docs/cli-roadmap.md §3.3）
- [x] E2E：`topic create` → 调和生成分区与副本放置 → 重启 SC 后状态恢复且不重复动作

## 落地记录

- **可插拔存储**：`MetadataStore{ load, save }`（注入式函数字段，与 `SegmentFile` / `OperatorEngine`
  同构）；首个后端 = 本地文件 `<data-dir>/metadata.json`（**临时文件 + rename 原子替换**，
  新增 `@fs.rename`）；另有内存后端供测试与无数据目录启动。**如实说明**：目前只有一个真后端，
  K8s CRD 是"接口已就位"而非已实现——README 决策会写清楚。
- **声明式 + level-triggered**：`topic create` 只**声明**（写元数据），不创建分区；SC 每 tick
  从 store 重读声明 → `core/cluster.reconcile` → 落盘 placement。`topic delete` 同理：
  **"不存在"本身就是指令**，没有删除事件。
- **CLI 命令面**（对标 docs/cli-roadmap.md §3.3）：`topic create --name T [--partitions N]
  [--replication-factor R] --remote SC`、`topic list`、`topic delete --name T`、
  `cluster status --remote SC`（节点 + 主题 + 每分区 leader/副本数/水位，水位是**向 leader 问的**，
  不是 SC 的记忆）。协议新增 `CMD_TOPIC_CREATE/LIST/DELETE=15/16/17` + `WireTopic` 编解码。
- **版本与并发**：元数据带单调 `version`；`create_topic` 是 load→改→save，**冲突检测留位**
  （单 SC 前提显式声明：本项目只跑一个控制面，第二个写入者会以结构化 `Conflict` 失败，
  而不是 last-writer-wins）。
- **校验单一真相**：topic 名走 `core/spec.valid_topic_name`（与 CLI 数据目录、spec 校验同一份
  白名单）；分区数/副本数有界。重复名 → `Rejected(already exists)`。
- **兼容性影响（已处理）**：T22/T23 的门禁脚本原先用 `topics.json` 直接喂声明，T24 之后
  声明唯一来源是 metadata store ⇒ 两个脚本改为用 `topic create` 声明（顺带成为命令面的门禁）。
- 门禁：`scripts/e2e-p3-metadata.sh` 6 条断言全绿（create 落盘 + 版本 → 重复名拒绝 →
  名字白名单 → list → 声明自动变 placement → **重启后声明与 placement 都不变**
  （同一份 cluster-state.json，重启不是再平衡）→ delete 触发移除）。
- 测试：`apps/cli/metadata_wbtest.mbt`（4 项：版本与顺序、拒绝与不落脏、删除与 miss、
  文件后端往返 + 无残留临时文件）。全量：native 148/148、wasm-gc 103/103、19 步门禁全绿。
- **未做（如实记录）**：客户端侧读钳制（`ReadMode.Committed` 随 FETCH 一起下发）没有做——
  它在 `core/replica` 里已就位并有单测，但接线需要改动 FETCH 应答形态（协议 v3），
  在里程碑末尾为一个半成品改线协议不划算；矩阵 #11 保持 ⚠️ 并写明这一半的归属。
