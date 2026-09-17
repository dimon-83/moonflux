# 52 — 控制面持有已应用的 spec

**What to build:** 让"集群的期望管道"成为**控制面状态**：`pipeline apply --remote <sc>` 把 spec 交给 SC，
SC 校验（复用 `core/spec` 的解析与 `compile_node` 的发布期检查口径——函数集解析需要 SC 自己的存储）、
持久化（修订号单调），并可通过 `CMD_PIPELINE_FETCH` 取回文档 + 修订号。

**Blocked by:** None.

**Status:** done (2026-09-17)

- [x] 协议（加法）：`CMD_PIPELINE_FETCH = 32`（无载荷 = 问修订；有载荷 = 取文档）与 `CMD_PIPELINE_APPLY = 33`
      （或复用既有 `CMD_APPLY_PIPELINE = 19` 到 SC？——**实现时定并留痕**：19 的语义是"部署到这台 broker"，
      本票要的是"部署到集群"，倾向新命令以免语义重叠）
- [x] SC 侧：持有 `{revision, spec_text, applied_at}`（`pipeline.json` 原子写）；修订单调；校验失败不落盘
      （与逐节点 apply 一样的"发布期拦截"口径）
- [x] 校验时函数集从 SC 自己的元数据存储解析（P6 的资产已在 SC 侧可达）
- [x] 单测：apply → 修订 +1；坏 spec 拒绝且不落盘；fetch 返回文档与修订

### 关账（2026-09-17）

落地：新命令 `CMD_CLUSTER_PIPELINE_APPLY = 32` / `CMD_CLUSTER_PIPELINE_FETCH = 33`（**不复用 19**：19 的语义是"部署到这台 broker"，集群语义单独一条命令——ticket 里要求的留痕）；`apps/cli/assets.mbt` 的 `ClusterAsset`（`pipeline.json` 原子写、修订单调、发布期校验复用 `parse_spec` + `compile_node`，**坏 spec 不落盘**）；`pipeline apply --remote <sc>` 为集群口径，`--data-dir` 仍为单机口径。
