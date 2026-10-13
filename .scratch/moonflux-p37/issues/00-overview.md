# P37 · 任务控制台（多任务地基 → 运行登记 → 可视化）

> 设计稿：[`docs/task-console.md`](../../../docs/task-console.md)（决策 79）｜裁定：多任务改平台、run-log 主题为准、首期 T0+T1

## 期与门禁

| 期 | 内容 | 门禁（可证伪） | 状态 |
| :--- | :--- | :--- | :--- |
| P37-1 | **多任务地基（本地口径）** | ✅ 2026-10-13（决策 81）：文档 v2 集合 + 一个文档级修订；按名 upsert / `--set` / `delete` / `list`；**取数按 topic 选链**；同主题冲突按名拒绝；v1 内存迁移；`moonflux_tasks` gauge。门禁 `e2e-p37-multi-task.sh` **10 腿** | ✅ **1b 完成 2026-10-13（决策 82）**：控制面集合文档 + 一个文档级修订、`apply --remote` 三形状 + `delete --remote`、节点整份采纳、坏文档拒收保留；门禁 `e2e-p37b-cluster-tasks.sh` **6 腿** |
| P37-2 | **运行登记（T0）** | ✅ 2026-10-13（决策 83）：`CMD_RUN_REPORT`（Node 类；设计稿的 register/heartbeat 合并成一条）+ `CMD_RUN_LIST`（只读）+ `run list`；`sc`/`serve` 同一张表、同一静默窗口；**stopped vs offline 可区分**、回收不碰 stopped；`<task>.run-log` + **run id 由起始偏移推导**；无标签 `moonflux_runs`/`moonflux_runs_offline`。门禁 `e2e-p38-run-registration.sh` **7 腿** | ✅ |
| P37-3a | **只读拓扑（T1 上半）** | ✅ 2026-10-13（决策 84）：内核 `view_model`（节点=进程、边=成文规则）+ CLI `pipeline view` + 页面拓扑面板；**CLI 与页面 JS 产物逐字节一致**（门禁在 node 里跑真产物）；ABI 3；坏 spec 结构化拒绝。门禁 `e2e-p39-console.sh` **5 腿** | ✅ |
| P37-3b | **任务清单 + 执行记录面板（T1 下半）** | ✅ 2026-10-13（决策 85）已完成：两个内核帧构造/解码（任务集合、运行表 + run-log 取数）；数值与 `pipeline list`/`run list` 同源；仍无像素门禁 | ⏳ |
| P37-4 | **每任务资产**：`tasks/<name>/spec.json`、`fns/*.json` + 修订绑定 + 漂移 | 往返一致、绑定修订、漂移可复现 | ⏳ |
| P37-5 | **生命周期 + Docker**：runner（start/stop/status，优雅停止）+ Dockerfile/compose + `/healthz` healthcheck | start→登记→记录→汇输出；stop→消失且标记 stopped；真死报 offline | ⏳ |
| P37-6 | **浏览器 playground**：第三 host + 页内算子执行 | native vs 浏览器 **逐字节一致** | ⏳ |

## 已知边界（写进文档，别在实现里忘掉）

- 控制台与 runner **都不是第二个控制面**；不新增端口与第二套命令语义。
- 浏览器**不能拥有日志**；页内 host 必须过 golden 对拍。
- **不给 `serve` 顺手加静态文件面**（要加是显式决策）。
- 文档级修订粒度较粗（任一任务变 ⇒ 全集合 +1）；细到每任务修订留作显式决策。
