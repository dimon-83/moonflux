# 任务控制台：多任务地基、运行登记与可视化（P37）

> **定位**：用户裁定的方向——**一个可视化应用管理 moonflux 的任务**：独立任务下管 `spec.json`/`fns.json`、
> 管生命周期、看执行记录（输入/输出/日志），支持**本地 / Docker / 浏览器 wasm**。
> **本文是设计稿与边界清单**；落地后回填"落地实录"（证据脚本）。
>
> **三个已裁定的前提**（决策 79）：
> 1. **任务模型 = 平台侧真支持多任务**（`topology.json` 改多管道 + 重定义修订语义），不是"一容器一任务"绕开；
> 2. **执行记录以 run-log 主题为准**（可复制、零新存储引擎），本地另留 stderr；
> 3. **首期 = 运行登记（T0）+ 只读拓扑/任务清单（T1）**。
>
> **日期**：2026-10-11

## 1. 今天的事实（动手前的底盘，全部核对过代码）

| 事实 | 出处 | 对设计的影响 |
| :--- | :--- | :--- |
| 已应用拓扑是**一节点一份**：`<data-dir>/topology.json = {pipeline, spec, cluster_revision?}` | [`apps/cli/pipeline.mbt`](../apps/cli/pipeline.mbt) | 多任务必须改这份文档的形状 |
| 采纳的**修订号存在同一份文档里**（`cluster_revision`），节点凭它判"控制面还没追上" | `apps/cli/assets.mbt` | 多管道文档天然可以带**一个**文档级修订 |
| 控制面每个节点一套 `RuleState`（单链 + 单管道名 + 时间戳） | [`apps/cli/rules.mbt`](../apps/cli/rules.mbt) | 取数路径要按 **topic 选链**，不是"选那条链" |
| **`pipeline run` 对平台完全不可见**（进程里没有 REGISTER/HEARTBEAT） | grep 实测 = 0 命中 | 运行登记是"任务管理"的地基，否则控制台只能猜进程 |
| 权限是闭合四类：`Root / ReadWrite / ReadOnly(is_data_read) / Node(is_node_command)` | [`core/auth`](../core/auth/) | 运行登记属**Node 类**（能伪造心跳就能骗平台），运行列表属只读 |
| 编辑器已就位：`web/editor/index.html` + `apps/editor-kernel`（js、ABI 2、13 导出，页面自断言 ABI） | 两个文件 | 控制台是**加一个页面/一层面板**，不是从零写前端 |
| `serve --ws` 同端口 WS 网关；非 upgrade 的 HTTP 得到带原因的 400 | [`apps/cli/hub.mbt`](../apps/cli/hub.mbt) | **今天 `serve` 不服务静态文件**——"一条命令启动管理台"要显式决定 |
| 观测面齐：`cluster status/offsets/segments`、`group describe`、`partition list` + `/metrics` + `/healthz` | CLI + P35 | T1 的活指标**复用既有命令**，不新增协议语义 |
| **没有任何 Docker 产物** | `find` 空 | Docker 形态要新建（含 healthcheck） |

## 2. 任务是什么（本设计的定义）

```
任务（task） = 名字
             + { spec.json, fns.json* }        ← 部署资产，版本化
             + 它拥有的主题（数据主题 / 状态主题 / run-log）
             + 它的运行（0..N 个，可被登记与查询）
```

三条推论（都是可证伪的规则，不是口号）：

1. **任务名来自 `spec.metadata.name`**，是它在文档里的唯一键；同名 apply = 该任务的新修订（upsert）。
2. **一个数据主题只能被一个任务声明为 `spec.topic`**：取数路径要靠 topic 找链，两个任务抢同一主题 = 语义不确定 ⇒ **apply 期按名拒绝**。
3. **状态主题与 run-log 属于任务**（各自独立），因此多任务不会互相污染状态（决策 77 的机制原样复用）。

## 3. 平台侧改动（P37-1 多任务地基）

> **落地实录 2026-10-13（本地口径，决策 81）**：文档形状、命令面、按 topic 选链、
> 同主题冲突按名拒绝、v1 内存迁移、`--set` 全集替换、`pipeline run --name` 都已落地，
> 门禁 `scripts/e2e-p37-multi-task.sh` **11 腿**全绿。**P37-1b 已落地 2026-10-13（决策 82）**：
> 集群侧持同一份集合文档 + 一个文档级修订，`apply --remote` 三种形状（信封）与
> `delete --remote`（Root-only），节点**整份采纳**（`cluster_revision` 与任务列表同时前进），
> 坏文档被拒且保留在跑的。门禁 `scripts/e2e-p37b-cluster-tasks.sh` **6 腿**。另外落地时确认了三条纪律：本地 apply
> **丢弃** `cluster_revision`；`/metrics` 里**不得出现任务名**（只出 `moonflux_tasks` 计数）；
> `rules active` 这类诊断必须走 **stderr**（块缓冲的 stdout 会让它"打印了但看不见"）。



| 项 | 今天 | 改成 | 兼容 |
| :--- | :--- | :--- | :--- |
| 文档形状 | `{pipeline, spec, cluster_revision?}` | `{pipelines: [{pipeline, spec}, ...], cluster_revision?}` | **读旧文档 = 单任务集合**（内存迁移）；写永远写 v2。旧数据目录与既有门禁不受影响 |
| 修订语义 | 一份文档一个修订 | **仍是一个文档级修订**：集合里任何一个任务变 ⇒ 修订 +1；节点整份采纳（绝不采纳"半套"） | P11 的"失败保留在跑的、每修订只报一次"原样成立 |
| 命令面 | `pipeline apply -f spec.json` | `apply` = **按 `metadata.name` upsert**；`apply --replace` = "这一个 spec 就是全集"；`apply --set` = "这份集合文档就是全集"；`delete --name X`；`list` | 旧用法从"替换"变成"upsert"：**这是行为变化**，所以 `--replace` 显式提供旧含义（p26 门禁当场证明：它往同一目录先后 apply 两个 spec，本意是替换） |
| 取数路径 | `rules.chain`（唯一链） | **每 topic 一条链**：fetch(T) 用"声明 T 为 topic 的那个任务"的链；没有则不变换（今天的行为） | `serve` 的客户端视角完全不变 |
| 节点兼容字段 | `applied_topic(data_dir)` | 明确为**名字序第一个任务**的主题（`leo` 兼容字段用），文档写明 | p3/p7 门禁不变 |
| 热采纳成本 | 重编译一条链 | 只重编译**变了**的任务（文档级修订 + 逐任务 spec 比对）；未变的任务不重编译 | P13"别让一圈变长" |

## 4. 运行登记（P37-2，T0）

**为什么必须有**：今天"任务在跑吗"这个问题平台答不出来——控制台只能猜进程，容器里更猜不到。

- **命令**（三件，权限显式归类）：
  - `CMD_RUN_REGISTER`（Node 类）：任务名、修订、data dir、host、pid、它读写的主题；
  - `CMD_RUN_HEARTBEAT`（Node 类）：每分区**输入偏移**、状态进度标记、批计数、最后错误；
  - `CMD_RUN_LIST`（只读）：控制台/CLI 查询。
  - **两个宿主都收**：集群口径归 `sc`（它已经在管节点），单机口径归 `serve`（同 P18/P22 把 topic/group 家族加进 serve 的先例）。
- **回收与"死法"区分**（诚实的关键）：同一个静默清扫窗口；**优雅停止 = 注销**（runner 先 flush、写 run-stop、再注销、才退出），**静默消失 = 被判离线**（进程被杀）。两者在列表里显示不同，不把 SIGKILL 冒充优雅。
- **run id 从日志推导**：`<task>@<revision>#<run-log 起始偏移>`。runner 先写 `run-start` 记录，**id 由此确定、不读时钟**（与"墙钟不进判据"同源）。
- **run-log 记录形状**（每事件一条，落在任务自己的 run-log 主题）：

  | 事件 | 内容 |
  | :--- | :--- |
  | `run-start` | 任务名、修订、数据目录、它读的主题与起点、非确定源声明 |
  | `batch` | 输入偏移区间、条数、输出条数、状态进度、耗时（**只报告**） |
  | `run-stop` | 原因（`exhausted` / `stopped` / `failed` / `drained`） |
  | `error` | 结构化错误（按名，不含凭据） |

- **metrics 的标签纪律**：控制台想要"每任务进度"，但**任务名是用户输入**——把它做成指标标签会开出无界基数。因此 `/metrics` 只暴露 `moonflux_runs`（总数）、`moonflux_runs_offline`（被判离线的数量）两个**无标签** gauge，每任务细节走命令（`cluster runs` / `run describe`）。这条要在门禁里钉住（任务名不得出现在 `/metrics` 输出里）。

> **落地实录 2026-10-13（P37-2，决策 83）**：运行登记已落地——`run list`（只读）
> 与 `CMD_RUN_REPORT`（Node 类，设计稿的 register/heartbeat 合并为一条：第一次即登记、
> 后续即心跳、最后一次带 `stopped`）；`<task>.run-log` 主题持有结构化事件，
> **run id = `<task>@<revision>#<run-start 偏移>`**（不读时钟）；`/metrics` 只出无标签的
> `moonflux_runs`/`moonflux_runs_offline`。门禁 `scripts/e2e-p38-run-registration.sh` **7 腿**，
> 其中第 2/3 腿正是"优雅停止 vs 被杀"：优雅停止在回收窗口之后**仍是 stopped**，
> 被杀的在窗口内变成 **offline**。**边界**：没有 `--control` 的运行不登记也不写 run-log；
> 集群上 `<task>.run-log` **必须先声明**（主题声明是操作员动作，P3/P18），写不了时运行
> **不登记但继续处理数据**——数据面不依赖被观察，也绝不编一个没有日志支撑的 id。

## 5. 控制台（P37-3，T1 与之后）

- **形状**：**客户端**，不是第二个控制面。静态页 + `apps/editor-kernel`（js）+ WS 到 `serve`。图上/列表里的每个事实都必须能追到内核或 CLI 的真相来源（P4 纪律：页面不解析协议字节、不自己推导拓扑）。
- **首屏三块**：
  1. **任务清单**：集合里的任务、修订、是否在跑、跑在哪些宿主、run-log 最新偏移；
  2. **只读拓扑**：`core/pipeline` 编译结果 → 节点/边（source → 变换链（标注 `expr`/`wasm`/`scalar`/`callout`）→ topic → sink），点节点看 spec 片段（只读）；
  3. **函数集面板**：**已有**（P27），不动。
- **执行记录页**：输入（topic 偏移区间 / file 路径）、输出（topic 或 stdout 摘要）、日志 = run-log 主题的事件流 + 本机 stderr（本地形态才有的即时视图）。
- **启动方式（要显式决定的一件事）**：今天 `serve` 不服务静态文件（非 upgrade 的 HTTP 得 400）。三条路：① 给 `serve` 加静态面（新职责，需决策：只读白名单、路径遍历防护）；② 任意静态托管 + 连 WS；③ 控制台自带小型静态服务（第三个进程）。**推荐 ②**：它零协议改动、零新端口，也符合"传输不是 API"。

## 6. 生命周期与三种形态（P37-5）

| 形态 | 生命周期由谁管 | 能做到 | 代价 / 边界 |
| :--- | :--- | :--- | :--- |
| **本地** | `moonflux task start/stop/status`（runner：fork/exec + 登记 + 优雅停止） | 全功能；日志即时 | runner **不做放置、不做选主**（不变成第二个 SC）；它只是"启动器 + 登记器" |
| **Docker** | 编排器（compose/k8s）；**一容器一任务** | 全功能；隔离最干净 | 要新产物（Dockerfile/compose，今天没有）；容器 healthcheck 直接用 `/healthz`（P35；standby 会报 503，编排器据此不导流） |
| **浏览器 wasm** | 无（浏览器不拥有进程） | ①编辑/校验/编译（内核纯函数，已有）②WS 连 broker ③**页内跑变换链**：算子 guest 无导入，可直接 `WebAssembly.instantiate` | **不能**拥有日志（无文件系统）、不能 file 源/汇。页内跑算子需要**第三个 host 实现**（native 是 wasmtime），必须过**同一套 golden 对拍**（native vs 浏览器逐字节一致），否则就是第二个语义 |

## 7. 分期与门禁（每期可独立收口，写进 `scripts/gates.sh`）

| 期 | 内容 | 可证伪门禁 |
| :--- | :--- | :--- |
| **P37-1** | 多任务地基（§3） | 两个任务并存、各自 apply/回滚互不影响；旧单任务文档**原样迁移**；两任务抢同一 `spec.topic` 在 apply 期**按名拒绝**；`--set` 替换语义与 upsert 语义各自可验 |
| **P37-2** | 运行登记 + run-log + metrics（§4） | 活着能在 `cluster runs` 看到；杀掉后**有界等待**内按名离线（且与优雅停止**可区分**）；run-log 事件与源/汇偏移**逐字节可对**；run id 可由日志重算（**不依赖时钟**）；`/metrics` 里**不出现任务名** |
| **P37-3** | 只读拓扑 + 任务清单（§5） | 视图模型的节点/边集合 == `core/pipeline` 编译输出；指标数值与 CLI **逐分区相等**；**不做像素门禁**（浏览器阶段由 agent/人驱动，与 p4-editor/p27 同形） |
| **P37-4** | 每任务资产（`tasks/<name>/spec.json`、`fns/*.json`）+ 修订绑定 + 漂移提示 | 往返一致；apply 绑定修订；漂移可复现；**编辑器不反向定义 spec**（所有编辑仍经 `mf_editor_build_spec`） |
| **P37-5** | 生命周期（runner + Docker） | start → 登记 → 记录出现 → 汇有输出；stop → 进程消失且运行标记 `stopped`（**不是 SIGKILL 冒充**）；真死被回收如实报 `offline/failed`；容器 healthcheck 反映真实健康 |
| **P37-6** | 浏览器 playground（第三 host） | **native vs 浏览器 host 逐字节一致**（扩展现有 `crosscheck-operators.sh` 的纪律） |

## 8. 明确不做（与既有决策一致）

- **第二个控制面**：控制台与 runner 都不做放置/选主/复制决策（决策 20、P13 纪律）。
- **不为控制台新增端口或第二套命令语义**：浏览器与 CLI 走同一 `MFS` 命令面（P4）。
- **不做 SQL 控制台、不画 SDF 的 state 对象/服务网格橙色边**（决策 54 §5、决策 78）。
- **不做像素级 UI 门禁**：只断言"视图模型 == 编译结果 / 数值 == CLI 来源"。
- **不做浏览器内持久日志**（IndexedDB 当日志后端 + 第三 host 的完整形态）：要就显式立项。
- **metrics 标签不接受用户输入**（§4）。

## 9. 边界与风险（已知）

| 风险 | 事实 | 处置 |
| :--- | :--- | :--- |
| 多任务让"文档级修订"粒度变粗 | 任一任务变 ⇒ 全集合修订 +1，所有节点重拉 | 采纳是**整份**的（安全 > 精细）；重编译按任务比对，只重编变的；粒度要不要细到"每任务修订"留作显式决策 |
| 运行登记把"谁在跑"变成新信任面 | 能伪造心跳就能骗平台 | Node 权限类 + 与节点同样的回收/告警；列表只读 |
| runner 可能与平台失联 | 网络断/SC 重启 | 失联的 runner **继续跑**（数据面不依赖登记），但状态显示为"未登记/失联"——如实，不假装健康 |
| 浏览器 host 是新语义面 | 三套 host（native / wasm / 浏览器） | 用同一套 golden 向量对拍；对拍不过就不发 |
| `serve` 服务静态文件会扩大攻击面 | 今天非 upgrade 一律 400 | 推荐控制台用**外部静态托管**（§5），把这一步留成显式决策而不是顺手加 |

## 维护规则

- 每期立项时按 §7 的门禁写 ticket；落地后回填"落地实录"（证据脚本 + CI run）。
- 任何"照 Studio 画"的冲动先回 §8：moonflux 没有的事实不画。
- 本文与 [`sdf-studio-exploration.md`](sdf-studio-exploration.md) 的关系：那篇是**对标探索**（Studio 有什么），本文是**工程落地**（本平台怎么长出任务管理）；两者不冲突，视图部分以本文 §5/§7 为准。
