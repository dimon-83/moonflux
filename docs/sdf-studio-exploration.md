# SDF Studio 图形化方案：对标探索与提案

> **定位**：对 Fluvio SDF 官方图形界面 [Studio](https://www.fluvio.io/sdf/studio/)（版本页 `sdf-beta11`）的概念、交互与信息面做一次对标，回答"moonflux 的编辑器该不该长成这样、哪些部分已有、哪些是缺的、缺的部分按什么顺序补"。**规约依据**：AGENTS.md §7（对标参考规则）与 §2 的 P4 纪律块（编辑器纪律：**编辑器渲染 spec，绝不反向定义**；传输不是 API；跨语言边界处的类型事实）。**边界声明**：本文是**探索与提案**——除已标注"已有"的部分外，其余均为候选工作项，未实现、不在门禁内；Studio 是参考系统的一个 UI，不是 moonflux 的规范来源。
>
> **日期**：2026-10-10

## 1. Studio 是什么（对标事实）

来自官方页面（[fluvio.io/sdf/studio](https://www.fluvio.io/sdf/studio/)）的要点，不加演绎：

| 事实 | 原文要点 |
| :--- | :--- |
| 定位 | "SDF Studio is the official user interface for Stateful Dataflows. Studio can be used to **visualize dataflow graphs and view relevant metrics**." |
| 启动方式 | 自托管：`sdf run --ui`（worker 内运行）/ `sdf deploy --ui`（部署到 worker）；`--port` 指定端口。Cloud 用户在 InfinyOn Cloud 网页面板里用 |
| 图的节点 | **两种**：topics 与 services |
| 图的边 | **两种**：灰色 = "a topic is acting as a source or sink for a service"；橙色 = "a service is referencing a state object owned by another service" |
| 交互 | 点击灰色边 → 右侧信息栏显示该 source/sink 关系的细节 |
| 指标 | 点击 service 上的 state 对象，或右下角 **Metrics** 按钮 → 以表格形式查看 state 对象 |

一句话概括它的形状：**一张由"主题 + 服务"组成的图，边上标注数据流向与服务间的状态引用，另有一个 state 表格视图作为指标面。**

## 2. moonflux 已有的部分（事实核对）

| 已有 | 位置 | 能力 |
| :--- | :--- | :--- |
| 规格编辑器（渲染器） | [`web/editor/index.html`](../web/editor/index.html) | 泳道式 spec 组装（source / transforms / topic / sink 的字段与增删），页面**不自己拼装或校验 spec**：图 → spec 只发生在内核 |
| 编辑器内核 | [`apps/editor-kernel/editor.mbt`](../apps/editor-kernel/editor.mbt) | `mf_editor_build_spec` / `mf_editor_validate` / `mf_editor_apply` / `mf_editor_produce` / `mf_editor_fetch` + 函数集面板（P27：列表/表单/删除/漂移标记），ABI 2 且页面断言版本 |
| 编译后的拓扑 | [`core/pipeline`](../core/pipeline/) | spec → 可运行拓扑（`pipeline plan/apply` 的同一份编译）；这是"图"的**唯一真相来源** |
| 传输 | `serve --ws` | 同端口 WebSocket（RFC 6455 升级），帧里装的仍是 `MFS`；**不为浏览器新增第二套命令语义或端口** |
| 观测面（CLI） | `cluster offsets` / `partition list` / `cluster status` / `cluster spu list` / `cluster segments` / `group describe` / `benchmark latency` | 逐分区 HW/LEO、leader、副本、段与可读起点、组份额与滞后、吞吐/延迟报告 |
| 生命周期日志 | 服务端 stderr（`opened`、`placed`、`automatic creation` 拒绝理由等） | 事件式诊断，已有门禁把它当结构计数器 |

**明确缺失的三块**（对应 Studio 的三件事）：

1. **没有"编译后拓扑"的图形视图**。页面画的是**待编辑的字段泳道**，不是 `core/pipeline` 编译出的节点/边；也没有"某主题被谁当 source/sink"的边语义。
2. **没有活指标叠加**。分区/水位/滞后只存在于 CLI 输出里，页面上看不到；也没有轮询刷新。
3. **没有 state 视图**。moonflux 没有 SDF 意义上的 state 对象（见 §5），所以这一块要重新定义成"日志侧的状态"，而不是照抄。

## 3. 概念对照

| Studio 概念 | moonflux 对应物 | 状态 |
| :--- | :--- | :--- |
| topic 节点 | 主题（分区日志） | ✅ 有数据模型；❌ 无图形节点 |
| service 节点 | **一份已应用拓扑**（`topology.json`，每节点一份） | ⚠️ 语义不同：SDF 的服务是"主题→主题"的常驻程序且可多服务并存；moonflux 每节点一份拓扑、spec 是入口式（外部源→主题→汇） |
| 灰色边（source/sink） | spec 的 `source` / `topic` / `sink` 三段 + 服务端取数路径 | ⚠️ 信息在 spec/拓扑里，未渲染 |
| 橙色边（跨服务状态引用） | **无对应物**（没有 state 对象、没有跨服务状态读） | ❌ 缺口 |
| 点边看细节 | 可以显示"这个主题的哪一端是源、哪一端是汇、变换链是什么" | ⏳ 候选（P1） |
| Metrics / state 表 | 逐分区 offsets/segments、组滞后、压实与 retention 报告 | ⚠️ 有数据、无视图；且"状态"的定义要改写（§5） |
| `sdf run --ui` 内嵌 webserver | `serve --ws` 同端口网关（既有） | ✅ 传输已就位，不需要第二个端口 |

## 4. 提案（三阶段，每阶段都可独立收口）

**P1 · 只读拓扑视图（推荐先做）**
- 内容：把 `core/pipeline` 的编译结果渲染成节点/边——`source` → 变换链（逐个节点标注类型：`expr` / `wasm` / `scalar`）→ `topic` → `sink`；点节点显示其 spec 片段（只读）。
- 约束：数据来自内核新增的一个**拓扑导出**（纯计算，`core/pipeline` 内已有编译结果，导出为 JSON 视图模型）；页面不解析协议字节、不自己推导拓扑（P4 纪律）。
- 门禁形态：`mf_editor_topology()` 的 wbtest（编译结果 → 视图模型的节点/边集合与顺序）+ 一条门禁腿断言"页面视图模型的节点/边集合 == 编译器输出"（**结构断言，不做像素断言**——照 P17 的纪律，UI 不做像素门禁，浏览器阶段由 agent/人驱动，与 `e2e-p4-editor.sh`、`e2e-p27-editor-functions.sh` 同形）。

**P2 · 活指标叠加**
- 内容：每个分区节点上叠加 HW/LEO/leader/副本；每条订阅关系上叠加组滞后。
- 数据来源：复用既有客户端命令的等价请求（`CMD_OFFSET_INFO`、`CMD_LEADER`、组描述），**不新增协议命令语义**；先做**轮询**（例如 1s），不做服务端推送（推送要新协议面，属显式立项）。
- 门禁形态：断言页面拿到的数值与 CLI 同源一致（逐分区相等），仍不做像素断言。

**P3 · "状态"视图（诚实版）**
- 内容：不做 SDF 的 state 表。moonflux 的"状态"是**日志侧的事实**：可读起点（floor）、段与索引状态、压实后的每键最新值（按 key 取样 `consume`）。
- 约束：视图只呈现**已有真相**（压实报告、floor、段列表），不引入"状态对象"这一新概念——那会把 SDF 的假设带进 moonflux（AGENTS §7）。
- 门禁形态：断言视图列出的可读起点/幸存键偏移与 `consume`、`cluster compact` 报告一致。

## 5. 非目标（明确不做）

- **不做 state 对象与跨服务状态引用（橙色边）**：moonflux 没有服务内持久键控状态（见 [`sdf-examples-port.md`](sdf-examples-port.md) §4）。若将来立项状态算子，橙色边才成为可渲染的事实；在此之前画它就是说谎。
- **不做 SQL 控制台**：查询不属平台职责（同上 §5）。
- **不新增端口、不新增命令语义**：浏览器与 CLI 走同一 `MFS` 命令面（P4 纪律）。指标叠加只用既有命令。
- **不让图反向定义 spec**：所有编辑仍必须经 `mf_editor_build_spec`；图形视图是**渲染器**，不是第二个真相。
- **不做像素级 UI 门禁**：UI 断言只到"视图模型 == 编译结果 / 数值 == CLI 来源"这一层，浏览器阶段由 agent/人驱动（与 P4/P27 一致）。

## 6. 边界与风险（动手前已知）

| 风险/边界 | 事实 | 处置 |
| :--- | :--- | :--- |
| 每节点一份拓扑 | 一个节点只有一份 `topology.json`；集群里各节点可以不同 | P1 的图是**单节点视图**；集群聚合视图需要向 SC + 各节点分别取数，明确留到 P2 之后 |
| 没有"主题→主题"的服务 | spec 是入口式；消费侧变换是节点级程序 | 图需如实分成"入口 pipeline"与"取数路径上的变换"两段，不假装有服务网格 |
| js 目标类型事实 | `Int64` 是 BigInt、`Bytes` 是 `Uint8Array`；页面动作必须 `guard()` | 视图模型一律用字符串/数字序列化（内核已如此：`mf_editor_feed` 等以 JSON 交付） |
| 应答解码次序 | JSON 应答必须先于 uleb 试探（P27 长夹具教训） | 新增的任何视图应答都走既有解码次序，不新开一条 |
| 指标轮询成本 | 每轮要问分区/组 | 复用 `ConnectionHub` 的连接与既有命令；不对数据路径加新的每 tick 工作（P13 纪律） |

## 维护规则

- 三个阶段各自立项时按 §4 的门禁形态写 ticket；落地后在本文回填"落地实录"（含证据脚本），并把对照表里的 ⏳ 改成 ✅。
- 任何"照 Studio 画"的冲动，先回到 §5：moonflux 没有的能力不画；画出来的每个节点/边都必须能在内核或 CLI 找到真相来源。
