# 24 — 元数据存储（可插拔）+ 调和驱动 placement

**What to build:** 元数据的持久化与驱动：可插拔存储接口 + 本地文件后端（首个实现），SC 的
调和循环按 Spec（期望状态）与集群实况（实际状态）计算动作并落账；重启后状态可恢复。

**Blocked by:** 19、21。

**Status:** ready-for-agent

- [ ] `MetadataStore` 接口（注入式函数字段）：`load() / save(state)`；本地后端 =
      `<data-dir>/meta/cluster.json`（原子写：临时文件 + rename）
- [ ] SC 调和循环：读 Spec（声明式文件或 CLI 提交）→ `reconcile` → 执行可执行动作
      （分配 leader / 副本集合）→ 保存状态；**幂等**：无差异时不写、不发动作
- [ ] 版本化：状态带单调版本号，写入冲突（并发 SC）报结构化错误（不做共识 —— 单 SC 假设显式声明）
- [ ] CLI：`cluster status`（节点 / 分区 / leader / HW-LEO 一览）、`topic create -p N -r R`
      （对标命令面，见 docs/cli-roadmap.md §3.3）
- [ ] E2E：`topic create` → 调和生成分区与副本放置 → 重启 SC 后状态恢复且不重复动作
