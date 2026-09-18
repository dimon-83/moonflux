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
| P1 | **连接器与外设**：Source/Sink 框架 + HTTP/文件/MQ + mbel 表达式 transforms + 客户端 SDK 雏形 | ≥3 个真实数据源接入跑通；改规则秒级生效 | ✅ 2026-09-15（`scripts/e2e-p1-connectors.sh`、`scripts/e2e-p1-rules.sh`；MQTT/Kafka 留后续） |
| P2 | WASM 算子沙箱：guest SDK + ABI + 全算子 + 双后端测试矩阵 | 算子语义与参考实现对拍一致 | ✅ 2026-09-16（`scripts/crosscheck-operators.sh`：native vs wasm 字节级一致 + trap/拒绝/超预算 fail-closed；`scripts/build-operators.sh` 构建门禁） |
| P3 | 复制 + 选主 + 元数据调和（本地多进程优先） | 故障注入通过（宕机/恢复/水位一致性） | ✅ 2026-09-16（`scripts/e2e-p3-{replication,failover,nodes,metadata}.sh`；`scripts/gates.sh` 含全部 19 步） |
| P4 | 客户端 SDK 完备 + Web 编辑器 + 部署形态（本地优先，K8s 可选） | 端到端：拖拽一条管道 → 运行 → 消费到数据 | ✅ 2026-09-17（`scripts/e2e-p4-{readmodes,ws}.sh`；编辑器闭环 `scripts/e2e-p4-editor.sh`，浏览器阶段由 agent/人驱动） |
| P5 | 并发与运维面：连接多路复用 + 多分区存储与数据路径 + 算子管理命令面 | 并发/多分区/算子管理三组门禁全绿 | ✅ 2026-09-17（`scripts/e2e-p5-{concurrency,partitions,operator}.sh`；**如实标注**：非 0 分区的复制仍在，矩阵 #10） |
| P6 | 规则资产：mbel 函数集（版本化规则资产 + 命令面 + spec 引用） | 函数集全生命周期门禁：部署→引用→发布期拦截→变换→更新 re-apply 生效 | ✅ 2026-09-17（`scripts/e2e-p6-functions.sh`，10 条断言） |
| P7 | 多分区复制：数据节点多分区宿主 + 逐分区水位/选主 + 协作式节点间调用 | 3 分区 RF=2 跨 3 节点：逐分区复制、分区隔离、逐分区换主、按分区截断报告 | ✅ 2026-09-17（`scripts/e2e-p7-partitions.sh`，7 条腿） |
| P8 | 存储完备：多段日志 + 稀疏索引 + 滚动/retention（安全下界由应用给出） | 分段对读者不可见、索引回退逐字节一致、retention 只删 floor 以下整段、撕裂尾只损失自身段、复制逐段字节一致 | ✅ 2026-09-17（`scripts/e2e-p8-storage.sh`，7 条腿；矩阵 #10 收口） |
| P9 | 消费组与托管偏移：协调者（控制面）+ 世代围栏 + range 分配 + 偏移持久化；retention 下界接最慢消费者 | 份额既覆盖又不重叠、成员死亡后接管续读、投递无缺口、过期世代提交被拒、偏移跨重启存活、消费者地板挡住 retention | ✅ 2026-09-17（`scripts/e2e-p9-groups.sh`，7 条腿；矩阵 #11 收口） |
| P10 | 复制走持久链接 + 预算语义（fuel 强制 / 墙钟观测） | 一次拨号、后续轮次复用（结构事实而非速度宣称）；墙钟只报告不设门禁 | ✅ 2026-09-17（`e2e-p7-partitions.sh` 的 link 腿；`e2e-p5-operator.sh` 的语义腿；矩阵 #14 收口） |
| P11 | 控制面资产下发：spec 与函数集由控制面持有、节点拉取 | 一次发布两个节点采纳并生效、修订不变不重拉、后加入节点自动取得、控制面消失仍服务、修订不回退 | ✅ 2026-09-17（`scripts/e2e-p11-assets.sh`，7 条腿） |
| P12 | **安全面**：内核鉴权语义（身份/角色/闭合权限表）+ 握手期认证 + TLS 传输（含节点间）+ 授权门禁 | 关闭认证时行为与 P11 完全一致且启动明示；无凭据/坏 token 被拒且不入日志；只读能读不能写；**客户端身份发节点命令被拒**；错 CA/无证书/明文被拒且服务端存活；TLS+认证下复制逐字节一致 | ✅ 2026-09-17（`scripts/e2e-p12-security.sh`，7 条腿；矩阵 #17–19） |
| P13 | **控制面改为 poll 驱动**：`sc` 接入 `ConnectionHub` + 逐帧分发器 + 步进式 TLS 握手 | 沉默对端不夺走健康节点的存活窗且不触发选举；慢客户端不阻塞他人命令；安全面不回退；真死仍判离线；并发客户端各自正确应答 | ✅ 2026-09-17（`scripts/e2e-p13-control-plane.sh`，5 条腿；执行中修掉环状死锁与 SIGPIPE，见决策 36） |

- 详细路线图、里程碑台账与排期见 [docs/project-roadmap.md](docs/project-roadmap.md)（进度管理单一真相，决策 37）；依据见报告 3.4 / 4.4 / 6.4。
- 阶段推进以**门禁**为准；门禁必须可证伪、可复现（对拍脚本 / 基准 / 故障注入），不得以"看起来能跑"代替。

**P3 集群语义纪律（做集群相关改动前先读；决策依据见 README 决策 17–21）**

- **复制方向固定为 follower-pull**：leader 永不 push。改动复制路径时不得反转方向或引入推送状态。
- **水位只有一个定义**：`HW = 副本集合（含 leader）各 LEO 的最小值`，**只前进不回退**；迟到的低 LEO 报告必须被忽略而不是应用。副本集合 ≠ 在线集合——已分配而离线的节点**留在集合里**（这正是副本死亡时 HW 停滞的原因）。
- **无 leader epoch，不得引入任期/截断假设**：数据面没有 epoch 是对标事实。分歧按"新 leader 的 LEO 唯一权威"处理，且**截断必须报告丢弃量**（README 决策 18）。
- **提名与提升是两个动作**：节点只能提升**被许给过自己**的分区（`core/replica.promote` 是唯一裁判）；**控制面不得主动拨号数据节点**（提名是状态，不是调用）——单线程循环互相调用会死锁。节点间调用一律带 deadline。
- **LRS 是算出来的**：成员资格由滞后阈值现算，不落库；落后只失去投票权，不停止复制。
- **声明式优先**：主题与放置的真相在元数据（`topic create` 写声明、SC 调和出放置）；**不存在"创建分区"命令**——那是事件，不是状态。

**P4 浏览器与编辑器纪律（改 Web/编辑器相关代码前先读；决策依据见 README 决策 22–24）**

- **编辑器渲染 spec，绝不反向定义**：图 → spec 只发生在 `apps/editor-kernel` 的 `build_spec`；页面（`web/editor/`）不得自行拼装或校验 spec，也不得解析协议字节——校验走 `core/spec`、拓扑走 `core/pipeline`、应答走 `core/client` 的编解码。
- **传输不是 API**：WebSocket 网关只搬运字节，WS 帧里装的仍是 `MFS`；不得为浏览器新增第二套命令语义或第二个端口。非 upgrade 的 HTTP 必须得到带原因的 400。
- **跨语言边界处的类型事实**：js 目标里 `Int64` 是 **BigInt**（传 number 会在内核里抛异常）、`Bytes` 是 `Uint8Array`；页面里任何动作都要 `guard()`（异常进日志）——**静默无响应的按钮是最坏结果**。
- **内核包的再导出边界**（实测）：`pub using` 只能在源码里（不能进 moon.pkg）、可再导出类型与函数但**不可**再导出枚举构造器、**不可**为外部类型定义方法；需要构造器的调用方直接 import 内核包。
- **已知缺口（最高优先级）**：`serve` 单连接串行（P1 遗留）——浏览器的长连接会饿死 CLI 与其它客户端；多路复用是下一步首位。


**P6 规则资产纪律（改函数集/表达式相关代码前先读；决策依据见 README 决策 27–28）**

- **函数集是可信资产，不是沙箱**：宿主侧 mbel 表达式体函数以"经评审的平台资产"为前提（与表达式规则同级）；**不可信标量函数的终态是 ABI v2 标量调用**（设计稿 [`docs/operator-abi-v2-scalar.md`](docs/operator-abi-v2-scalar.md)，尚未实现）——不得声称现有路径可承载不可信输入。
- **校验分两层，不得含糊**（实测边界，ticket 36 §评估校核）：资产级 = 名字白名单 + 结构 + **纯度**（mbel 的名字/参数/函数体规则由注册委派给 mbel 作为唯一权威）；类型检查只覆盖**被引用闭包**（mbel 按调用点推断参数类型，"整集合类型校验"不可得）。发布期两道闸（静态检查 + Vm 编译）都在 apply 时执行。
- **纯度黑名单 = `now`**：`builtin/time.mbt` 中唯一读宿主时钟者（`date`/`duration` 是字符串解析、`timezone` 被裁到 UTC）；扫描方向是宁可误拒（字符串字面量里的 `now` 也会被拒）。新增不确定性内建时**必须同步黑名单**并留痕。
- **表达式语法面以 `?:` 为准**：顶层表达式不支持 `if {}` 块（Vm 编译阶段拒绝；`if` 仅在函数体内可用）。门禁已钉住两侧。
- **版本在 apply 时绑定**：spec 引用集合**名**，`topology.json` 记录解析到的 revision；集合更新**不自动生效**，re-apply 才换绑——这条是"spec 即不可变部署"的推论，不得改成隐式热更新。
- **错误文本有界**：错误出口截断到 `apps/transform` 的 `MAX_ERROR_CHARS`（实测深递归错误约 4.4 KB/次，逐记录失败会放大）。

**P7 多分区纪律（改复制/数据节点相关代码前先读；决策依据见 README 决策 29–30）**

- **分区是复制的单元**：水位、故障、换主、分歧截断全部按 `(topic, partition)` 独立；改动复制路径时不得引入任何"节点级"的进度或水位。
- **放置只来自控制面**：节点从心跳应答学习自己的分配，请求先到用 `CMD_LEADER` 兜底一次；**不要给节点加第二条放置规则**。唯一的退化情形是"应用管道指向的主题没有任何声明"——自持 partition 0，且只在此时。
- **写入只认 leader**：非宿主与跟随者必须结构化拒绝并附 leader 地址（`ERR_WRONG_ROLE`），不得"先收下再想办法"。
- **复制走持久链接**（P10）：每分区一条长连接到 leader，握手一次、每轮一请求一应答；**任何错误即丢链接**（超时请求可能留下在途应答，读成下一条的答案是静默协议污染），下一轮重拨——失败仍是重试，不是事件。不要退回到"每轮一个短连接"。
- **节点间调用必须是协作式的**：单线程节点在等对端应答时**必须继续服务自己的连接**（`peer_call` + `pump`）。同步阻塞的节点间调用会把环状拓扑变成互相失聪——这是 P7 花了整轮调试换来的结论，且它会让节点周期长于存活超时而**被控制面误判死亡**。任何新的节点间调用都要走这条路，并保持"失败 = 下一个 tick 重试"。
- **每分区每 tick 至多一次调用**：能合并的探测就合并（`SYNC_FETCH` 的应答已经带回 leader 末端与水位，不要再单独问一次）；ACK 只在有新闻时发。
- **截断退到帧边界**：分歧回归用 `truncate_to_boundary`（leader 的 LEO 可能落在本副本帧内部，日志不存半个批）；丢弃量必须报告。
- **每分区上报是加法段**：节点记录尾部可选段，缺段 = 空表；**不要为此升帧版本号**（旧解码器不校验读尽是本条的前提，改动前先看 `decode_node_full` 的注释）。

**P8 存储纪律（改日志/段/索引/保留策略前先读；决策依据见 README 决策 31）**

- **段边界只能是帧边界**：滚动发生在写入*之前*（"满了开下一段"）。不要改回"写后再滚"——`serve` 每请求重开日志，空尾段会被 open 按崩溃语义丢弃，阈值就永远不生效（P8 实测）。
- **段序列是链**：base 严格递增；中间空段 = 空洞 → `Storage` 拒绝，不得修补；空尾段在 open 时丢弃（写目标消失的日志是坏的，不是小的）。
- **索引是加速器，不是真相**：任何疑虑（缺失/长度/CRC/base/单调性/越界）一律回退全扫，两条路径必须逐字节一致；封存时才写索引，最后一段借用恢复扫描重建。
- **retention 只删整段**，且 `段末 ≤ floor`；`floor` 由应用给出（本项目 = 已提交前缀），内核不猜；策略默认关闭，每次删除必须报告（段 base、记录数、字节、新的可读起点）。**永不动活动段**。
- **删除之后的读是结构化拒绝**（`OffsetOutOfRange`）："没了"≠"空"，不得返回空窗口。
- **时间口径由应用传入**（`roll_due(now_ms, ...)` / `apply_retention(floor, now_ms, ...)`）：内核不读时钟（AGENTS §5）。

**P9 消费组纪律（改组成员/偏移/分配相关代码前先读；决策依据见 README 决策 32）**

- **协调者是控制面**：成员只报状态、只提请求；"谁持有什么"的答案只有一个权威。不要在成员侧实现第二套分配或世代。
- **分配随心跳应答下发**，成员不需要"拿分配"的独立轮次；心跳 ≠ 提交——**空闲成员也必须心跳**，否则会被按静默清扫并丢掉分区。
- **世代围栏**：只有成员集合（或声明主题）变化才换代；任何提交带世代，**过期即拒**（`ERR_GROUP`）。**不存在特权写入路径**：运维用的 `group commit` 与成员走同一请求、受同一围栏。
- **语义是至少一次**：提交在处理之后；再平衡窗口内**允许**短暂重复读（门禁断言的是"稳定后不交叠 + 投递无缺口"），**不得**声称恰好一次。
- **未提交 ≠ 落后**：从未提交的组不参与 retention 下界（它还没开始），下界只由有提交的组决定；消费晚于删除得到结构化 `OffsetOutOfRange`。
- **偏移是持久状态**：`groups.json` 原子写、损坏即 fail（静默重置消费进度不可接受）；成员集合是内存态（推导存活，重启后由心跳重建）。

**P11 资产下发纪律（改 apply / 资产 / 节点拉取相关代码前先读；决策依据见 README 决策 34）**

- **权威在控制面，节点是缓存**：`pipeline apply --remote <sc>` 是集群口径；单机口径（`--data-dir`，`cluster_revision` 为 0）保持不变，两者是不同的话。
- **pull 而非 push**：控制面不得主动拨号数据节点（决策 20）；修订号随心跳应答下发，文档在修订前进时才按需拉取。
- **节点仍然自己校验**：编译是纯函数（同文档同拓扑），函数集按需拉取后节点仍过一遍发布期检查——控制面是权威副本，不是唯一守门人。
- **修订不回退**：本地修订更高 = "控制面还没追上"，不得覆盖；拉取/校验/编译失败一律**保留在跑的管道**。
- **失败只报一次（每个修订）**：`AdoptionState` 是这条的实现；任何新的周期重试路径都要照此处理，否则日志很快就没人看了。

**P12 安全面纪律（改认证 / 授权 / 传输 / 凭据相关代码前先读；决策依据见 README 决策 35）**

- **默认关闭，但必须明示**：`auth.json` 不存在即无认证（本地开发口径不变），启动日志**必须**打 `authentication DISABLED (...)`。静默的安全模式本身就是漏洞——不要让"这次是不是在裸跑"需要考古。
- **认证前不服务任何命令**：三处服务端（数据 hub、`serve` 会话、SC 控制端口）无一例外；新增服务端入口时，"先认证再分发"是入门的必要条件。
- **权限表是闭合的**：`core/auth.permit` 未列出的命令对非 Root 一律拒绝。新增协议命令**必须**显式归类（数据读 / 自己组的成员命令 / 节点命令 / Root），漏掉的效果是"测试里被拒"，不是"生产上没人发现"。
- **判定在分发入口一处，且在解析载荷之前**：不要在每个 handler 里各写一遍 `permit`，也不要在解析之后再判定（门禁断言错误码恰为越权码，用顺序钉住这一点）。
- **节点身份与客户端身份分开**：`Node` 只用于 REGISTER/HEARTBEAT/SYNC_*/CONFIRM/LEADER/资产拉取。**能伪造 `SYNC_ACK` 就能推动所有人的 committed read 依赖的高水位**；节点凭据的泄漏等价于节点身份被冒用（门禁 5c 实测：一个幽灵 REGISTER 真的进入了副本集合）。因此**不得**把节点命令并入 ReadWrite/Root 的顺手权限。
- **TLS 客户端必须校验证书**：`VERIFY_PEER` + `SSL_set1_host` 是默认，不是选项。OpenSSL 客户端默认 `SSL_VERIFY_NONE`——装了 CA 却不校验照样握手成功，**比不做 TLS 更糟，因为它看起来是成功的**。测试要断言"拒绝"，而不是"连通"。
- **出站调用必须有期限**：TLS 会话没有 SO_RCVTIMEO；"节点不得挂住节点"（P7 的教训）在 TLS 之上只能由期限保证（`tls_conn_with_timeout` 的 io deadline）。新增任何出站路径都要带上期限与 pump。
- **凭据只做参数，内核不读环境**：`core/*` 不得读环境变量或凭据文件（`token` 是参数）；宿主层（apps/cli）才做"从哪读凭据"的决定。库若自己读凭据，它的每个嵌入者都会替它做一个它没做的安全决定。
- **凭据不进日志**：门禁有一条腿专门 grep 日志。任何打印请求/应答的调试路径都要先想一遍它会不会带上 token。
- **安全面改变不了数据面对拍**：`e2e-p12-security.sh` 第 7 腿要求 TLS+认证之下复制仍**逐字节一致**。任何"为了安全而稍微改一下数据路径"的想法都要先过这一关。

**P13 事件循环纪律（改 hub / 节点循环 / 复制拨号 / 任何服务端循环前必读；决策依据见 README 决策 36）**

- **一个线程，谁都别等**：三种服务端（`serve` / `spu` / `sc`）是同一个形状——accept、poll、Service、flush，绝不阻塞在单个对端上。新增服务端入口照抄这个形状。
- **等待必须是"步进"，不是"阻塞 + 期限"**。TLS 握手是范例：`adopt` 只 attach（socket 先转非阻塞），每轮 `step_handshake` 推进一步，期限只用来判定"沉默"。**不要**引入"每轮最多等 N 次"这类预算——限制等几次改不了等本身，沉默连接占着 backlog 位置仍会饿死真实客户端（实测：drain 红 / 每轮一次红 / 步进绿）。
- **泵必须贯穿所有等待**（P7 的教训，P13 又被踩到一次）：任何"等对端"的循环都要在等待中服务自己的连接——**包括握手期**。"我们还没有在途请求所以不用泵"是错的推理：你等 WELCOME 的时候，可能正是别人在等你的节点（三节点环状同时拨号 → 互相等死，`sample` 显示 100% 卡在 `SyncLink::connect`）。
- **写不能杀进程**：垫片已进程级忽略 SIGPIPE，因此写向消失的对端返回 `EPIPE`——所有调用点必须把它当"这个连接死了"处理（关连接、继续服务其他人），不得让错误上抛成进程退出。
- **误判与不检测是两种失败**：门禁断言用**症状计数器**（`is offline` / `leader of` / `offering`）而不变，并配一条**反例腿**（真死必须仍判离线）。改调度时两边都要过。
- **在事件循环里加任何新工作前先问**：它会不会让这个循环的一圈变长？一圈的长度就是"最坏情况下多久才轮到别的连接"，而这直接换算成活 heartbeat 与误判离线之间的距离。
## 3. 目录与包结构（MoonBit 约定）

```
moonflux/
├── core/        # 内核：不声明 supported_targets（= 全后端）；只依赖 moonbitlang/core
│   ├── codec protocol log spec pipeline operator   # P0–P2
│   ├── cluster replica                             # P3：控制面模型与调和 / 复制语义
│   ├── client                                      # P4：客户端内核（帧编解码 + 会话，全后端可编译）
│   └── auth                                        # P12：身份/角色/闭合权限表/常数时间比较（纯计算）
├── adapters/    # 薄适配层：每包声明单目标（abi-wasm → "wasm"；net-native → "native"；net-js → "js"）
│   ├── fs-native net-native                        # P0–P1
│   └── wasmtime-native                             # P2：算子宿主（dlopen，无链接期依赖）
└── apps/        # 入口包：is-main，按目标打包（算子模板 / cli / 服务端 / web-client）
    ├── cli（produce/consume/serve/pipeline/spu/sc/topic/cluster）
    ├── client connectors transform                 # P1：客户端 SDK / 连接器 / mbel 执行器
    ├── operator-sdk operator-*                     # P2：guest SDK 与算子模块
    └── editor-kernel                               # P4：Web 编辑器的内核侧（js 目标）
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

完成任务前逐项确认（**`scripts/gates.sh` 一次跑完全部**；`scripts/gates.sh fast` 跳过 E2E 门禁）：

- [ ] `moon check` 通过；`moon fmt` 无 diff（`moon fmt --check`）；`moon info` 的 `.mbti` 变更符合预期
- [ ] `moon test` 在 **≥2 个后端**通过（内核包必须：wasm 与 native）
- [ ] 多后端编译矩阵：`moon build --target wasm|wasm-gc|js|native`（core 包全过）
- [ ] 涉及 codec/算子：golden vectors 对拍通过；涉及执行路径：预算与超时行为测试通过
- [ ] 生成物一致性：`tools/gen_*.py --check` 全部 up to date（**改数据文件后必须重跑生成器**；生成器按 `moon fmt` 排版输出，故 fmt 对生成文件是 no-op）
- [ ] 涉及集成（mbel / 参考系统互操作）：附可复现脚本与对照输出
- [ ] 文档同步：README / 报告章节 / 本文件金规则表（如决策有变更并注明依据；规范见 §10）

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

### 8.1 算子沙箱纪律（P2 起）

- **算子 ABI 定稿即契约**：v1 的 7 个导出名固定（`core/operator` 中的常量），spec 不暴露 `export`；要改 ABI 就升版本号并同时改宿主与 guest SDK——**新的 ABI 版本走显式版本记录**，不得"尽力而为"地兼容。
- **guest 无导入**：算子模块不得有 import 段（无 WASI、无 IO、无时钟、无随机源）。这不是约定而是结构性事实——宿主的"纯函数"假设建立在它之上；构建门禁 `tools/probe_operator_exports.py` 以编译器 WAT 为真相源。
- **配置只走 `mf_op_init`**：spec 的 `config` 对象原样透传给 guest，宿主不解释其语义（语义属算子）。
- **双预算**：记录数上限 + 指令数（fuel）上限随 tier 收紧；预算超限报 `BudgetExceeded`，**不**报裸 trap。fuel 是确定性计量（无时钟），重放同一批数据得到同一结果——这条与内核红线同源。
- **墙钟只报告、不设门禁**（决策 33）：耗时由 adapter 测量（`last_call_ms`），超档只告警/打印（`over_time_hint`）；**不得**把墙钟接成 pass/fail 判据——那会让同一批数据因机器负载时而通过时而失败，破坏重放。要收紧就调 fuel（确定性）。
- **失败一律 fail-closed**：算子拒绝 / trap / 预算超限都必须变成结构化错误，且**已产出的一半批次绝不落 Sink**（`scripts/crosscheck-operators.sh` 的 fail-closed 四条腿是这条纪律的门禁）。
- **语义变更必须对拍**：任何算子语义调整都要有 native-vs-wasm 的字节级证据；测试向量放数据文件（`scripts/testdata/operator-golden.txt`，由 `tools/gen_operator_golden.py` 生成），手改即失败。

### 8.2 函数集纪律（P6 起）

- **资产即文档**：函数集以一份 JSON 文档部署（`function-set create --file fns.json`），字段名与 mbel JSON v1 对齐（`name`/`params`/`body`/`description`）；**未知字段一律拒绝**——一个说了平台会忽略的话的资产，是在欺骗它的评审人。
- **参数必须声明**：资产不暴露 mbel 的自由标识符自动提取（`params: None`）——body 里的拼写错误必须在发布期失败，而不是静默变成一个参数。
- **一个集合一个 revision**：同名 create 就是该资产的新修订（revision 单调 +1，回复说明是 deployed 还是 updated）；集合内重名、关键字名、聚合名冲突、参数重复、空 body 均由 mbel 的注册校验拒绝（唯一权威，勿另写一套规则）。
- **逐节点资产**：函数集存在节点自己的元数据文档里（与 topic 声明同库同版本号），集群内不做分发——与现行"逐节点 apply"一致；跨节点一致性由 apply 时绑定 revision 来核对。
- **改了资产必须 re-apply**：门禁 `scripts/e2e-p6-functions.sh` 的第 6 条腿钉住"更新后未 re-apply 行为不变"——不要把这个行为"优化"掉。

## 9. 不做清单（Anti-patterns）

- ❌ 未经 §1.1 四检的移植（携带 Rust 依赖 / 假设、破坏内核红线）；❌ 把"整体照搬"当目标（移植是加速手段，不是项目目标）。
- ❌ 内核引入平台依赖 / async / FFI；❌ 首期引入 WIT / 组件模型（除非明确立项）。
- ❌ 跨线程共享引擎实例；❌ 绕过预算 / 超时执行不可信规则。
- ❌ UI 先于 spec（编辑器永远渲染 spec，不反向定义规范）。
- ❌ 未经对拍就声称"与参考实现一致"；❌ 无门禁数据就推进阶段。

## 10. 文档规范（文档资产与写作规则）

> 本规范是 §5（台账）、§6（文档同步）、§7（留痕）在文档面的展开；规则取自仓库既有实践，新增/修改文档一律按此执行。

**文档分层与单一真相**（同一事实只有一个权威位置，其他位置链接引用、不复制）：

| 文档类型 | 位置 | 权威内容 |
| :--- | :--- | :--- |
| 项目介绍 | [README.md](README.md) | 定位 / 核心主张 / 快速开始 / 能力与范围摘要 / **文档导航** / **关键决策记录**（权威位置） |
| 工作规约 | 本文件（AGENTS.md） | 金规则 / 内核红线 / 验证流程 / 文档规范等执行纪律（§1–§10） |
| 立项评估报告 | [docs/fluvio-moonbit-evaluation.md](docs/fluvio-moonbit-evaluation.md) | 对标事实：§2 功能实录、§4 后端、§5 mbel、§6 编辑器 |
| 参考系统作业规则 | [docs/fluvio-reference-guide.md](docs/fluvio-reference-guide.md) | 在 `~/workspace/fluvio` 内的 agent 硬规则 |
| 对标语义台账 | [docs/compatibility-matrix.md](docs/compatibility-matrix.md) | 每条对标语义的验证状态与证据入口（状态图例的单一真相） |
| 架构说明 | [docs/architecture.md](docs/architecture.md) | 分层与包清单 / 事件循环 / 协议 / 存储 / 复制与控制面 / 安全 / 算子 / 验证体系（"为什么是这个形状"的唯一位置） |
| 实用文档 | [docs/user-guide.md](docs/user-guide.md) | 构建 / 快速开始 / CLI 参考 / 集群与消费组 / 安全配置 / 存储运维 / 故障排查（"怎么用"的唯一位置） |
| 功能矩阵 | [docs/feature-matrix.md](docs/feature-matrix.md) | **能力清单的单一真相**：功能 × 状态 × 证据入口（与兼容性矩阵分工：那里管"对标语义验证状态"） |
| 进度管理 | [docs/project-roadmap.md](docs/project-roadmap.md) | **进度与排期的单一真相**：阶段详情 / 里程碑台账 / 待办（README 只留摘要与链接，决策 37） |
| 规划类 | `docs/*-roadmap.md`（实例 [cli-roadmap.md](docs/cli-roadmap.md)） | 分阶段映射、边界声明、勘误清单 |
| 实证类 | `docs/*-spike.md`（实例 [p2-wasm-host-spike.md](docs/p2-wasm-host-spike.md)） | 探针命令与输出、选型依据、落地回填 |
| 工作项（ticket） | `.scratch/moonflux-p{N}/issues/NN-slug.md` | What to build / Blocked by / Status / 勾选清单 |

- **命名与登记**：文档文件名 kebab-case 英文，`docs/` 平铺；ticket 编号 `NN` **跨阶段全局连续**（P0=01–08、P1=09–13、P2=14–18，不按阶段重号）。新增文档必须**同时登记两处资产索引**（README「资产索引」与 §11）：只建文件不登记 = 未完成；文档头部为一级标题 + `>` 引言块（定位 / 规约依据 / 边界声明）。
- **引用规范**：引用报告用「报告 §x.y」；引用决策用「README 决策 N」；引用规约用「AGENTS.md §N」；引用代码用 `路径:符号名`（如 `apps/cli/main.mbt` 的 `usage()`）。**不引用易漂移的行号**；表格单元格内的 `|` 必须转义为 `\|`；图示用 mermaid 代码块（实例：报告 §4.5.1）。
- **证据与状态**：论断必须可证伪——附脚本路径（`scripts/e2e-*.sh`）、测试 / golden 向量入口、或探针命令与原始输出；禁用"看起来能跑"式结论（§2）。对标语义状态统一用 ✅ 对拍通过 / ⚠️ 部分验证 / ⏳ 未验证 图例（compatibility-matrix 为单一真相）。日期一律 `YYYY-MM-DD`；报告与规划类文档首部标注日期 / 版本。
- **留痕与同步**（变更时按表执行）：

| 变更类型 | 必须同步 |
| :--- | :--- |
| 语义借鉴 / 架构选型 | README「关键决策记录」（编号 + 日期 + 报告章节依据；§7） |
| 金规则变更 | README「关键决策记录」+ 本文件 §1（规则表与依据列） |
| 阶段 / 门禁状态变化 | [docs/project-roadmap.md](docs/project-roadmap.md) + §2 阶段表（涉评估结论时同步报告） |
| 新增 / 变更对标语义 | compatibility-matrix 入表或状态迁移（附证据入口） |
| 命令面 / 目录结构变化 | §3 目录与包结构；（如涉及 CLI）回填 `docs/cli-roadmap.md` |
| 新增文档 | 两处资产索引登记 |

- **维护**：文档尾部可带「维护规则」段（实例：compatibility-matrix、cli-roadmap）；发现的缺陷先在所在文档记录（勘误表 / 备注），修复按 ticket 追踪；实证类文档在选型落地后**回填**「落地实录」，保持文档与实现一致（实例：p2-wasm-host-spike.md）。

## 11. 资产索引

| 资产 | 位置 | 说明 |
| :--- | :--- | :--- |
| 项目介绍 | [README.md](README.md) | 定位 / 核心主张 / 快速开始 / 能力摘要 / 文档导航 / 关键决策记录（权威） |
| 架构总览 | [docs/architecture.md](docs/architecture.md) | 架构说明的单一位置：分层 / 事件循环 / 协议 / 存储 / 复制 / 安全 / 算子 / 验证体系 |
| 实用文档 | [docs/user-guide.md](docs/user-guide.md) | 操作手册的单一位置：构建 / 快速开始 / CLI / 集群 / 安全 / 运维 / 排障 |
| 功能矩阵 | [docs/feature-matrix.md](docs/feature-matrix.md) | 能力清单的单一真相：功能 × 状态 × 证据入口 |
| 路线图与进度 | [docs/project-roadmap.md](docs/project-roadmap.md) | 进度与排期的单一真相：阶段详情 / 里程碑台账 / 待办 |
| 立项评估报告 | [docs/fluvio-moonbit-evaluation.md](docs/fluvio-moonbit-evaluation.md) | 架构与选型的全部证据（7 章） |
| 对标参考工作规约 | [docs/fluvio-reference-guide.md](docs/fluvio-reference-guide.md) | 在 Fluvio 参考仓库作业时的硬规则 |
| CLI 命令工具规划 | [docs/cli-roadmap.md](docs/cli-roadmap.md) | 命令面分阶段规划（对标 Fluvio CLI；README 决策 13） |
| 兼容性矩阵 | [docs/compatibility-matrix.md](docs/compatibility-matrix.md) | 每个对标语义的验证状态与证据入口（P2 算子沙箱条目见 #12/#14） |
| 算子沙箱取证 | [docs/p2-wasm-host-spike.md](docs/p2-wasm-host-spike.md) | wasmtime 进程内宿主的问题取证（类型镜像尺寸、后台编译 panic） |
| 集群门禁脚本 | `scripts/e2e-p3-{nodes,replication,failover,metadata}.sh` | P3 故障注入门禁（注册/复制/选主/元数据；断言映射见 `.scratch/moonflux-p3/issues/25-failover-gate.md`） |
| Web 编辑器与页面 | `web/editor/` + `apps/editor-kernel` | spec 的渲染器（拖拽 → 部署 → 运行 → 消费）；门禁 `scripts/e2e-p4-editor.sh` |
| 段文件记录解码器 | `tools/decode_log_frames.py` | 直接读段文件（段文件即协议流）验证记录，不需要连接 |
| 安全面取证客户端 | [scripts/mfs_probe.py](scripts/mfs_probe.py) | 独立实现的 MFS 客户端（Python）：安全门禁用它伪造节点命令，断言针对**服务端授权**而非 CLI 愿意发什么 |
| mbel 表达式引擎 | `~/workspace/mbel` | 动态规则层的候选内核 |
| mbel-orch 设计 | `~/workspace/mbel-orch` | 算子/插件分发体系的设计参考 |

---

*本规约随项目阶段演进；**金规则的任何变更必须同步 README「关键决策记录」并注明依据章节**。*
