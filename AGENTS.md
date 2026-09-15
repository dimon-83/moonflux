# AGENTS.md — moonflux 项目规约

> 本文件是 **moonflux 的项目章程与 agent 工作规则**：任何在本仓库工作的 agent（或人）开始任务前必读。
> 项目定位与范围 → [README.md](README.md)｜技术依据与证据 → [docs/fluvio-moonbit-evaluation.md](docs/fluvio-moonbit-evaluation.md)｜对标参考规则 → [docs/fluvio-reference-guide.md](docs/fluvio-reference-guide.md)

## 0. 项目身份（不可动摇）

- **moonflux = MoonBit 全栈开发的流式计算平台，与 Fluvio 具备同等的能力与地位。**
- **Fluvio 是对标参考系统**（设计参考、语义参照、互操作对象）——**不是宿主、不是依赖、不是上游**。
- 名称：**Moon**Bit × **F**lux（流）。
- 做任何设计决策前先自问：这是 moonflux 在自建能力，还是把 Fluvio（或 Kafka）的假设当成了规范？

## 1. 金规则（Golden Rules）

| # | 规则 | 依据 |
| :--- | :--- | :--- |
| 1 | **对标为主、移植可选**：默认借鉴设计独立实现；**不反对代码级移植**——能显著加速实现时允许（Rust→MoonBit 翻译），但必须通过「MoonBit 语境合理性」四检（§1.1） | README 决策记录 1 |
| 2 | **一内核多后端**：`core`（纯计算）/ `adapters`（薄、单目标）/ `apps`（按目标打包）；依赖方向 `core ← adapters ← apps`，由 MoonBit `supported_targets` fail-fast **编译期强制** | 报告 4.5 |
| 3 | **内核红线**：零 IO、零第三方依赖（仅 moonbitlang/core）、无 panic 解析、确定性（时钟/随机注入） | 报告 4.5.3 |
| 4 | **后端顺序：Native 先行**（Source/Sink 与数据面/客户端需要**独立的外部读写**——网络 / 文件 / 协议 / MQ / 硬件，WASM 沙箱不能自主 IO）→ WASM（数据路径内算子沙箱，可编程差异化）→ JS/wasm-gc（浏览器）；内核全后端可编译由 CI 矩阵保持；门禁不过不推进 | README 决策记录 3（修订自报告 4.4） |
| 5 | **并行与分布**：宿主并行 × guest 虚拟；计算单元无状态；per-core 独占实例，**禁止跨线程共享实例** | 报告 4.6 |
| 6 | **动态规则**：mbel 为表达式引擎（不复制其源码）；预算 + 宿主墙钟超时**双约束** | 报告 5.3 / 5.4 |
| 7 | **编辑器 spec-first**：PipelineSpec 是单一真相，UI 只是 spec 的渲染器 | 报告 6.3 |

### 1.1 「MoonBit 语境合理性」四检（移植的前置门槛）

代码级移植（含 Rust→MoonBit 翻译）**允许**，但每一处移植必须四项全过；**验收标准与自建一致（§6），不降标**：

1. **结构合规**：产物符合一内核多后端——平台依赖（async / IO / FFI）一律留在 adapters，绝不进 core；
2. **习惯合规**：以 MoonBit 范式重写，不照搬 Rust 特有机制（proc-macro 代码生成、trait 对象化、tokio 运行时假设等 → 替换为 MoonBit 的 derive / 接口注入 / 显式状态机）；
3. **依赖合规**：不因移植引入第三方依赖（内核尤为严格）；Rust 生态 crate 不随逻辑迁入——其能力要么用 core 库重实现，要么以接口抽象 + 适配层提供；
4. **合规与留痕**：Apache-2.0 兼容性检查 + 出处署名（NOTICE / 文件头注明来源与改动）；"移植 vs 自建"决策记入 README 决策记录；语义基线仍以参考系统对拍为准。

### 1.2 部署基底与阶段解耦（重要）

**数据面与控制面的推进不依赖 K8s**：

- P0–P3 全部在**本地**（单机 / 多进程）推进与验收；K8s 是 P4 的**可选**部署目标之一（与本地单二进制并列）；
- 数据面、复制、选主、元数据调和是**架构能力而非 K8s 能力**——任何部署模型都需要（参考系统在 local 模式与 K8s 模式共用同一套控制器与复制协议；其 K8s 只贡献两件事：**元数据后端**（CRD）与**生命周期自动化**（operator / Helm））；
- 因此元数据存储按**可插拔接口**设计：本地存储为首个实现，K8s CRD 为后续可选后端；二进制按"单程序多子命令"（all-in-one / sc / spu）设计，本地多进程即最小集群。

## 2. 当前阶段与门禁（Roadmap 摘要）

| 阶段 | 里程碑 | 门禁（可证伪） | 状态 |
| :--- | :--- | :--- | :--- |
| P0 | **Native 最小闭环**：内核 codec + fs/net-native 适配 + 单机最小日志 + CLI + 文件源 → topic → stdout 汇贯通 | 端到端 demo 可复现；协议样本对拍通过 | ✅ 2026-09-15（`scripts/e2e-p0.sh`、`scripts/crosscheck-protocol.sh`） |
| P0′（并行） | PipelineSpec v1alpha1 + CLI 编译/计划 | 一份 spec 可编译为可运行的进程拓扑 | ✅ 2026-09-15（`scripts/e2e-p0p.sh`） |
| P1 | **连接器与外设**：Source/Sink 框架 + HTTP/文件/MQ + mbel 表达式 transforms + 客户端 SDK 雏形 | ≥3 个真实数据源接入跑通；改规则秒级生效 | 未启动 |
| P2 | WASM 算子沙箱：guest SDK + ABI + 全算子 + 双后端测试矩阵 | 算子语义与参考实现对拍一致 | 未启动 |
| P3 | 复制 + 选主 + 元数据调和（本地多进程优先） | 故障注入通过（宕机/恢复/水位一致性） | 未启动 |
| P4 | 客户端 SDK 完备 + Web 编辑器 + 部署形态（本地优先，K8s 可选） | 端到端：拖拽一条管道 → 运行 → 消费到数据 | 未启动 |

- 详细路线图与依据见 README「路线图」与报告 3.4 / 4.4 / 6.4。
- 阶段推进以**门禁**为准；门禁必须可证伪、可复现（对拍脚本 / 基准 / 故障注入），不得以"看起来能跑"代替。

## 3. 目录与包结构（MoonBit 约定）

```
moonflux/
├── core/        # 内核：不声明 supported_targets（= 全后端）；只依赖 moonbitlang/core
├── adapters/    # 薄适配层：每包声明单目标（abi-wasm → "wasm"；net-native → "native"；net-js → "js"）
└── apps/        # 入口包：is-main，按目标打包（算子模板 / cli / 服务端 / web-client）
```

- 包依赖只允许 `core ← adapters ← apps` 单向；任何方向的违规会被 `moon build --target X` 的依赖 fail-fast 直接拦截——**不要试图绕过，它是架构纪律的执行者**。
- 新增包先写 `moon.pkg` 的 `deps` 与（如适用）`supported_targets` 声明，再写代码。
- 内核包若被迫需要某平台能力 → 说明该能力应上移到 adapters；这是设计信号，不是障碍。

## 4. MoonBit 编码约定（继承 mbel 工程实践）

- 代码按 `///|` 块组织，块内独立、顺序无关；格式化用 `moon fmt`。
- **提交前**：`moon info && moon fmt`，检查 `.mbti`（生成接口）差异是否符合预期——`.mbti` 无变化 = 对外接口未变，通常是安全重构。
- 测试：黑盒 `_test.mbt`（只测公开 API，放 `*_test` 包）；白盒 `_wbtest.mbt`（需观察内部细节时，随包存放）；**语料/向量放数据文件，不内联**。
- 断言选择：稳定结果用 `assert_eq` / `assert_true`；结构化调试输出用 `debug_inspect` 快照（别用 `Show` 做调试）；输出变化时 `moon test --update`。
- 覆盖率：`moon coverage analyze > uncovered.log`，重点盯内核包的解析与边界分支。
- 错误处理：内核解析器一律 `Result` / `suberror`（零成本错误路径），不使用 panic 路径处理不可信输入。

## 5. 内核红线（违反即返工）

- 内核包**不得**引入：async 运行时、文件/网络 IO、FFI、平台条件编译——任何一项都会毒化后端矩阵（fail-fast 会先炸，但设计时就应避免）。
- 解析不可信输入（协议字节、表达式、外部配置）返回 `Result`/`suberror`；长度 / 索引 / varint 边界**显式校验**；以随机种子做解析路径的模糊自测。
- **不使用系统时钟与随机源**：一律以 `Clock` / `Random` 接口注入，保证同输入同输出——这是 golden 对拍与故障重放的前提。
- **字节级 / 语义级对拍**：codec 与算子行为以 golden vectors 钉死（向量来源：对参考系统的观测、公开语料、协议样本），并维护一份"兼容性矩阵"，记录每个对标语义的验证状态。
- 内核按**能力包**增量生长：独立测试、独立对拍、独立发布节奏；内核 API 设冻结策略（变更走显式的版本记录）。

## 6. 验证流程（"完成"的定义）

完成任务前逐项确认：

- [ ] `moon check` 通过；`moon fmt` 无 diff；`moon info` 的 `.mbti` 变更符合预期
- [ ] `moon test` 在 **≥2 个后端**通过（内核包必须：wasm 与 native）
- [ ] 多后端编译矩阵：`moon build --target wasm|wasm-gc|js|native`（core 包全过）
- [ ] 涉及 codec/算子：golden vectors 对拍通过；涉及执行路径：预算与超时行为测试通过
- [ ] 涉及集成（mbel / 参考系统互操作）：附可复现脚本与对照输出
- [ ] 文档同步：README / 报告章节 / 本文件金规则表（如决策有变更并注明依据）

## 7. 对标参考系统（Fluvio）使用规则

- 参考仓库位于 `~/workspace/fluvio`（干净的上游检出）：**不在其中做 moonflux 的功能开发**；对照实验可临时进行，实验产物不留存。
- 在参考仓库内做研究 / 对照 / 互操作测试时，**遵循 [`docs/fluvio-reference-guide.md`](docs/fluvio-reference-guide.md)**（线协议版本化、存储与复制不变量、SmartModule ABI、验证清单）——避免误读参照系。
- **语义借鉴必须留痕**：任何"照参考系统设计"的决策，记入 README「关键决策记录」并注明报告章节依据。
- 禁止把参考系统（或其同侪 Kafka）的默认假设无意识带入 moonflux——参考系统自身没有消费者的消费组、数据面无 leader epoch、默认读为未提交；凡是"看起来大家都这样"的语义，先查报告 1.2/2.x 的事实再定。

## 8. 动态规则层（mbel）集成规则

- 引擎来源：`~/workspace/mbel`（v0.3.3）；**不在本仓库复制其源码**——以依赖引用或 core-wasm 制品形式使用。
- 两种形态：MoonBit 宿主**库内嵌**；跨语言 / 沙箱用 **core-wasm + 薄 ABI 适配**（与内核适配层同构）。
- 集成前对照报告 5.5 生产化清单：宿主墙钟超时、预算分级（内部 / 用户 / 租户）、plain wasm 目标测试、热路径"编译一次、复用到每记录"。
- 规则资产（表达式 + 函数集 + env）必须版本化；发布前过 **Compile mode 静态检查**（`unknown name` / 类型错误在发布期拦截，而非运行期）。

## 9. 不做清单（Anti-patterns）

- ❌ 未经 §1.1 四检的移植（携带 Rust 依赖 / 假设、破坏内核红线）；❌ 把"整体照搬"当目标（移植是加速手段，不是项目目标）。
- ❌ 内核引入平台依赖 / async / FFI；❌ 首期引入 WIT / 组件模型（除非明确立项）。
- ❌ 跨线程共享引擎实例；❌ 绕过预算 / 超时执行不可信规则。
- ❌ UI 先于 spec（编辑器永远渲染 spec，不反向定义规范）。
- ❌ 未经对拍就声称"与参考实现一致"；❌ 无门禁数据就推进阶段。

## 10. 资产索引

| 资产 | 位置 | 说明 |
| :--- | :--- | :--- |
| 项目定义 | [README.md](README.md) | 定位 / 能力对标表 / 范围 / 路线图 / 决策记录 |
| 立项评估报告 | [docs/fluvio-moonbit-evaluation.md](docs/fluvio-moonbit-evaluation.md) | 架构与选型的全部证据（7 章） |
| 对标参考工作规约 | [docs/fluvio-reference-guide.md](docs/fluvio-reference-guide.md) | 在 Fluvio 参考仓库作业时的硬规则 |
| mbel 表达式引擎 | `~/workspace/mbel` | 动态规则层的候选内核 |
| mbel-orch 设计 | `~/workspace/mbel-orch` | 算子/插件分发体系的设计参考 |

---

*本规约随项目阶段演进；**金规则的任何变更必须同步 README「关键决策记录」并注明依据章节**。*
