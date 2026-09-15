# moonflux — MoonBit 全栈流式计算平台

> **正式立项**：2026-09-15 · **项目目录**：`~/workspace/moonflux` · **对标参考**：[Fluvio](../fluvio) · **组件资产**：[mbel](../mbel)（动态规则引擎候选）、[mbel-orch](../mbel-orch)（函数分发平台设计参考）

## 定位

**moonflux 是一个用 MoonBit 全栈开发的流式计算平台，与 Fluvio 具备同等的能力与地位。**

- **全栈 MoonBit**：从内核（编解码 / 线协议 / 算子语义 / 存储 / 复制状态机）到系统集成（异步网络 / TLS / 集群管理）、从 CLI 到 Web 可视化编辑器，单一语言贯穿全栈；借此换取三样东西——native 与 WASM 双形态的可移植性、沙箱安全与内存安全、AI 辅助开发效率。
- **能力对等**：目标能力面与 Fluvio 同级——分区提交日志、复制与选主、推送式消费、版本化线协议、客户端 SDK、沙箱化可编程算子、连接器框架、云原生部署、可视化拖拽管道编辑器。
- **与 Fluvio 的关系**：Fluvio 是**对标系统与设计参考**（架构研究、能力基准、语义参照），**不是宿主、不是依赖**，moonflux 独立成体系。立项评估报告对 Fluvio 的全面剖析（架构 / 功能 / 协议 / 复制 / 算子运行时）是 moonflux 的设计知识库；报告中"移植可行性"章节的技术结论（分层递进、能力缺口清单、验证门禁）转化为 moonflux 的工程路径与选型依据。

**名称**：**Moon**Bit × **Flux**（流）。

## 能力对标（目标态）

| 能力域 | Fluvio（参考实现） | moonflux（目标） | 启动阶段 |
| :--- | :--- | :--- | :--- |
| 内核与线协议 | 自研二进制协议（版本化 + derive 宏 + varint） | 自建（MoonBit 核心库的 LEB128 / 字节序原语齐备） | P0 |
| 连接器框架（Source/Sink） | Connector 框架 + 外部仓库生产件 | 自建：**Native 外部读写框架**（HTTP / 文件 / MQTT / Kafka / 硬件直采）+ mbel 表达式 transforms | P0 框架 / P1 连接器 |
| 分区日志存储 | commit log（segment / index / checkpoint / retention） | 自建（P0 单机最小 → P3 完整；单写多读 + 零拷贝目标） | P0 |
| 沙箱化可编程算子 | SmartModule（wasmtime + core-wasm ABI） | 自建同等能力；叠加 mbel **动态表达式规则**（改规则免编译） | P2（Native 先行，WASM 后置） |
| 客户端 SDK | Rust + wasm 浏览器 + 多语言 | MoonBit native（P1 雏形）→ wasm 浏览器（P4） | P1 / P4 |
| 复制与选主 | follower 拉取 + ISR 等价（LRS）+ 集中提名选主 | 自建（对标同语义，含水位与故障恢复） | P3 |
| 控制面与元数据 | SC 调和循环 + 多类 Spec + K8s operator | 自建（level-triggered 调和 + 声明式 Spec；**元数据存储可插拔：本地存储优先，K8s CRD 可选**） | P3 |
| 管道构建体验 | CLI / 配置文件（无拖拽编辑器） | **可视化拖拽编辑器（一等产品特性）** | P0′ / P4 |

## 核心主张

1. **全栈单语言**：MoonBit 贯穿全栈，"一内核多后端"是手段而非目的——同一份内核定义可编译为 WASM 沙箱算子、Native 服务端、浏览器客户端三种形态（架构纪律由 MoonBit `supported_targets` 依赖 fail-fast 在编译期强制，见报告 4.5）。
2. **动态性内建**：表达式 / 算子即配置——mbel 表达式引擎作为动态规则层，规则变更秒级生效、免编译免重启；可视化拖拽编辑器直接建立在"配置即规则"之上（报告 5.4 / 6.3）。
3. **对标为主、移植可选**：以 Fluvio 为设计参考自建同等能力；**不反对代码级移植**——若能显著加速实现（Rust→MoonBit 翻译），经「MoonBit 语境合理性」四检后即可采用（AGENTS.md §1.1），验收门槛与自建一致。报告 3.3 的能力缺口（异步运行时、TLS、K8s client、WASM 宿主嵌入）是自建 backlog 与选型清单——MoonBit 生态每补齐一项，实现成本就下降一档（同时也是移植可行性的输入）。
4. **分阶段达成、门禁推进**：全平台不可能一步到位；按 **Native 最小闭环 → 连接器与外设 → WASM 算子沙箱 → 分布式 → 全平台体验** 的递进路径推进（**Native 先行**：Source/Sink 与数据面需要独立的外部读写能力），每个阶段设可证伪的门禁（见路线图）。

## 范围

**目标态（全平台）**：即上方「能力对标」表——数据面（存储 / 复制 / 读写服务）、控制面（元数据调和 / 放置与选主 / 集群生命周期）、协议与 SDK（线协议 / 多路复用 / native + wasm 客户端）、可编程层（沙箱算子 + 动态表达式规则）、产品化（CLI / PipelineSpec / 可视化编辑器 / K8s 部署）。

**分期入口（工程路径）**：P0 算子沙箱与内核起步（1–2 周 PoC）→ P0′ PipelineSpec 先行 → P1 算子 SDK 完备 → P2 数据面 MVP → P3 复制与控制面 → P4 全平台体验。

**暂不涉及**：SDF 等价的有状态 SQL 层（远期，视需要）；生产连接器目录（按需求逐步自建）。**代码级移植不是禁区**——按模块做"移植 vs 自建"决策（四检见 AGENTS.md §1.1）。

## 资产索引

| 资产 | 位置 | 说明 |
| :--- | :--- | :--- |
| **项目规约** | [`AGENTS.md`](AGENTS.md) | 项目章程：金规则 7 条 / 内核红线 / 验证流程 / 对标参考使用规则 / 不做清单 |
| **立项评估报告 v1.6** | [`docs/fluvio-moonbit-evaluation.md`](docs/fluvio-moonbit-evaluation.md) | 七章：Fluvio 全景 / 功能详解 / 分层路径与能力缺口 / Native×WASM 后端 / mbel 评估 / 可视化编辑器 / 结论路线图 |
| 对标参考工作规约 | [`docs/fluvio-reference-guide.md`](docs/fluvio-reference-guide.md) | 在 Fluvio 参考仓库内作业（研究/对照/互操作测试）时的 agent 硬规则（自 fluvio 仓库迁入） |
| mbel 表达式引擎 | [`../mbel`](../mbel) | v0.3.3；moonflux 动态规则层的候选内核（评估与生产化清单见报告第五章） |
| mbel-orch 设计文档 | [`../mbel-orch`](../mbel-orch) | 函数管理与分发平台（设计阶段，可作为 moonflux 算子/插件分发体系的设计参考） |

## 路线图（首期）

| 阶段 | 里程碑 | 交付物 | 门禁（可证伪） |
| :--- | :--- | :--- | :--- |
| **P0**（2–4 周） | **Native 最小闭环** | 内核 codec 子集 + `fs-native` / `net-native` 适配 + 单机最小分区日志 + CLI（produce/consume）+ 文件 Source → topic → stdout Sink 贯通 demo | ✅ 达成（2026-09-15）：`scripts/e2e-p0.sh` 全绿；协议对拍 `scripts/crosscheck-protocol.sh` 全绿 |
| **P0′**（并行） | 产品化地基 | `PipelineSpec` v1alpha1 + CLI `pipeline apply/plan`（声明式管道编译） | ✅ 达成（2026-09-15）：`scripts/e2e-p0p.sh` 全绿；spec 编译为可运行拓扑 + plan 差异预览 |
| **P1** | **连接器与外设** | 连接器框架 + HTTP/文件/MQTT/Kafka Source & Sink + mbel 表达式 transforms（Native 内嵌）；协议服务化与客户端 SDK 雏形 | ✅ 达成（2026-09-15）：`scripts/e2e-p1-connectors.sh`（file/stdin/http 三源 + stdout/http 双汇）与 `scripts/e2e-p1-rules.sh`（不重启 serve 秒级换规则）全绿；MQTT/Kafka 连接器与多路复用按路线图留待后续 |
| **P2** | WASM 算子沙箱 | 算子 guest SDK + 沙箱 ABI + 全算子 + WASM×Native 双后端测试矩阵 | 算子语义与参考实现对拍一致 |
| **P3** | 分布式能力 | 复制（ISR 等价语义）+ 选主 + 元数据调和（本地多进程优先） | 故障注入通过（节点宕机 / 恢复 / 水位一致性） |
| **P4** | 全平台体验 | 客户端 SDK 完备（native + wasm）、Web 拖拽编辑器、部署形态（**本地单/多进程优先，K8s 可选**） | 端到端：拖拽一条管道 → 运行 → 消费到数据 |

> **为什么 Native 先行**（2026-09-15 修订）：数据源（Source）与数据汇（Sink）需要**独立的外部读写能力**——网络 / 文件 / 协议 / MQ / 硬件直采，**WASM 沙箱不能自主 IO**，只能做宿主中介的计算；连接器与数据面又是平台的第一梯队能力，因此承载它们的 Native 必须先行。WASM 保留为"数据路径内算子沙箱"（可编程差异化），在 P2 落地；**内核全后端可编译的纪律由 CI 矩阵从第一天保持**（不依赖 WASM 先行来倒逼，见 AGENTS.md §4/§5）。
>
> **K8s 与阶段的关系**：P0–P3 **不依赖 K8s**，全部在本地单机/多进程推进与验收；K8s 仅是 P4 的可选部署目标之一，且只贡献两件事——元数据后端（CRD）与生命周期自动化（operator/Helm）。数据面、复制、选主、元数据调和是**任何部署模型都需要**的架构能力（对标参考系统在 local 与 K8s 两种模式下共用同一套控制器与复制协议）。

## 目录规划（代码启动后）

```
moonflux/
├── README.md              # 本文件：项目定义
├── AGENTS.md              # 项目规约（章程：金规则 / 内核红线 / 验证流程）
├── docs/                  # 评估报告与设计文档
├── core/                  # 内核：codec / protocol / 算子语义 / 存储 / 复制状态机（全后端可编译）
├── adapters/              # abi-wasm / net-native / net-js / fs-native（单目标薄适配）
└── apps/                  # 算子模板 / cli / 服务端 / web-client（按目标打包）
```

> `core → adapters → apps` 的一内核多后端结构由 MoonBit `supported_targets` 依赖 fail-fast 在编译期强制（报告 4.5）；内核零 IO、零第三方依赖是纪律红线。

## 关键决策记录

1. **架构对标为主、移植为辅（可选）**：以 Fluvio 为设计参考自建同等能力平台；**允许在能显著加速实现时做代码级移植**（Rust→MoonBit 翻译），须过「MoonBit 语境合理性」四检（AGENTS.md §1.1）；Fluvio 不作为宿主或依赖；每个模块的"移植 vs 自建"决策随该模块立项记入本条；
2. **算子沙箱用经典 core-wasm ABI 语义**（对标 SmartModule 的设计取舍：极小 ABI + 版本化载荷 + 预算治理）；不引入 WIT/组件模型作为首期依赖（报告 1.2.8 / 3.6）；
3. **后端实现顺序：Native 先行**（2026-09-15 修订）——Source/Sink、数据面、客户端都需要**独立的外部读写**（网络 / 文件 / 协议 / MQ / 硬件直采），WASM 沙箱只能做宿主中介的计算、不适合承载连接器；WASM 后置为"数据路径内算子沙箱"形态（P2），JS/wasm-gc（浏览器客户端）最后；**内核的全后端可编译纪律由 CI 矩阵保持**（不依赖 WASM 先行倒逼）。本条修订自报告 4.4 的原始排序（其"WASM 先行"以"扩展层切入"为前提，与全平台定位的前置条件不同；修订注见报告 4.4）；
4. **动态规则内核选型 mbel**：MoonBit 宿主库内嵌；跨语言/沙箱形态用 core-wasm + 薄 ABI（报告 5.3 / 5.4）；
5. **编辑器 spec-first**：先立 PipelineSpec 与 CLI 编译器，UI 只是 spec 渲染器（报告 6.3）；
6. **并行与分布归宿主架构**：计算单元无状态化，"宿主并行 × guest 虚拟"（报告 4.6）。
7. **PipelineSpec 文档格式用 JSON**（2026-09-15）：MoonBit 内核仅依赖 `moonbitlang/core`（无 YAML 解析器），v1alpha1 以 JSON 为规范文档格式；JSON 是 YAML 子集，纯 JSON 语法书写的 YAML 文档天然兼容。YAML 全量解析视需求另立依赖决策；
8. **P0 会话协议为内部帧格式**（2026-09-15）：`serve/produce --remote/consume --remote` 使用 10 字节头 `MFS` 帧封装线协议批帧，仅供 P0 demo；完整版本化协议服务化与多路复用按路线图属 P1，届时替换并纳入对拍矩阵；
9. **P0′ 拓扑的执行形态**（2026-09-15）：`pipeline apply` 持久化 `topology.json`（pipeline 名 + spec 文档），编译为纯函数——重编译即还原拓扑；`pipeline run` 在单进程内顺序执行编译出的拓扑（source→broker→sink）。多进程/远程执行在 P1 协议服务化基础上接管；含 `mbel-p1` 能力标记的拓扑 run 期拒绝执行（可证伪的未实现声明）。
10. **动态规则作用于消费路径**（2026-09-15，P1）：mbel transforms 在 fetch/回放路径逐条执行（对标 SmartModule 的消费侧流处理语义）——历史数据按当前规则重现，这也是「改规则秒级生效」可证伪的关键；规则资产（表达式）随 spec 版本化，`pipeline apply` 时做发布期静态检查（mbel Compile mode：语法/未知函数/未知变量/类型错误全部拦截），运行期 compile-once + Vm 程序缓存复用到每记录。
11. **规则热重载机制**（2026-09-15，P1）：`serve` 每个请求前 stat `topology.json`（纳秒 mtime），变更即重编译换入——`apply` 后无需重启；重载失败保留旧规则并告警（绝不静默、绝不空转）。秒级精度不足会漏检测（秒内两次 apply），故 fs 适配器 mtime 用纳秒。
12. **协议服务化与 SDK 连接抽象**（2026-09-15，P1）：帧协议 v2 = `MFS` magic + 版本 2 + cmd + 请求 id + 长度；会话以 HELLO/WELCOME 握手（主版本不匹配回结构化 `unsupported-version`，v1 时代对端被明确拒绝而非静默断开）；错误帧带稳定错误码。客户端 SDK（`apps/client`）把连接抽象为注入式函数字段（TCP / socketpair），使全流程可进程内单测；多路复用与并发连接仍在后续里程碑（P1 保持顺序会话）。

## 待办（下一步）

- [x] `git init` 与远端仓库（如需）（远端待配）
- [x] P0 达成：内核 codec/protocol/log + fs/net-native 适配 + CLI + 端到端 demo（2026-09-15）
- [x] P0′ 达成：PipelineSpec v1alpha1 + pipeline plan/apply/run（2026-09-15）
- [ ] P1 启动：mbel 表达式 transforms 接入（含 spec.transforms 执行）、版本化协议服务化（替换 P0 会话帧）、多分区/并发连接
- [x] 生成项目规约 [`AGENTS.md`](AGENTS.md)（2026-09-15）；随代码结构落地更新其目录与命令章节

---

*本文件由项目立项日生成（2026-09-15）；结构随报告版本演进，重大变更请同步更新「关键决策记录」。*
