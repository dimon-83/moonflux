# P37 · 任务控制台（多任务地基 → 运行登记 → 可视化）

> 设计稿：[`docs/task-console.md`](../../../docs/task-console.md)（决策 79）｜裁定：多任务改平台、run-log 主题为准、首期 T0+T1

## 期与门禁

| 期 | 内容 | 门禁（可证伪） | 状态 |
| :--- | :--- | :--- | :--- |
| P37-1 | **多任务地基（本地口径）** | ✅ 2026-10-13（决策 81）：文档 v2 集合 + 一个文档级修订；按名 upsert / `--set` / `delete` / `list`；**取数按 topic 选链**；同主题冲突按名拒绝；v1 内存迁移；`moonflux_tasks` gauge。门禁 `e2e-p37-multi-task.sh` **10 腿** | ✅ **1b 完成 2026-10-13（决策 82）**：控制面集合文档 + 一个文档级修订、`apply --remote` 三形状 + `delete --remote`、节点整份采纳、坏文档拒收保留；门禁 `e2e-p37b-cluster-tasks.sh` **6 腿** |
| P37-2 | **运行登记（T0）**：`CMD_RUN_REGISTER/HEARTBEAT/LIST`（Node 类 / 只读）+ 静默回收 + run-log 主题 + run id 由日志推导 + 两个无标签 gauge | 活着可见、杀掉后有界离线且与优雅停止可区分；run-log 与源/汇偏移逐字节可对；run id 可重算；`/metrics` 无任务名 | ⏳ |
| P37-3 | **只读拓扑 + 任务清单（T1）**：内核导出视图模型；页面渲染任务清单/节点边/执行记录 | 视图模型 == 编译输出；数值与 CLI 逐分区一致；无像素门禁 | ⏳ |
| P37-4 | **每任务资产**：`tasks/<name>/spec.json`、`fns/*.json` + 修订绑定 + 漂移 | 往返一致、绑定修订、漂移可复现 | ⏳ |
| P37-5 | **生命周期 + Docker**：runner（start/stop/status，优雅停止）+ Dockerfile/compose + `/healthz` healthcheck | start→登记→记录→汇输出；stop→消失且标记 stopped；真死报 offline | ⏳ |
| P37-6 | **浏览器 playground**：第三 host + 页内算子执行 | native vs 浏览器 **逐字节一致** | ⏳ |

## 已知边界（写进文档，别在实现里忘掉）

- 控制台与 runner **都不是第二个控制面**；不新增端口与第二套命令语义。
- 浏览器**不能拥有日志**；页内 host 必须过 golden 对拍。
- **不给 `serve` 顺手加静态文件面**（要加是显式决策）。
- 文档级修订粒度较粗（任一任务变 ⇒ 全集合 +1）；细到每任务修订留作显式决策。
