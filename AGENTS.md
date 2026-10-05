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
| P14 | **键语义与键控压实**：`produce --key/--key-separator` + `cluster compact`（偏移不变的删旧留新） | 键全链路可见；压实只删被取代的记录并保留偏移（空洞可读）；floor 之上不动；两副本各自压实后逐段字节一致；新副本跨空洞追赶 | ✅ 2026-09-18（`scripts/e2e-p14-compaction.sh`，8 条腿；矩阵 #20） |
| P13 | **控制面改为 poll 驱动**：`sc` 接入 `ConnectionHub` + 逐帧分发器 + 步进式 TLS 握手 | 沉默对端不夺走健康节点的存活窗且不触发选举；慢客户端不阻塞他人命令；安全面不回退；真死仍判离线；并发客户端各自正确应答 | ✅ 2026-09-17（`scripts/e2e-p13-control-plane.sh`，5 条腿；执行中修掉环状死锁与 SIGPIPE，见决策 36） |
| P15 | **载荷预算贯穿数据路径**：分批生产 + 有界窗口消费 + 复制窗口字节预算 + 传输缓冲与协议限制一致 | 20 MiB 文件端到端逐字节一致；跨分块偏移连续；超限记录/超限帧**结构化拒绝且有日志**；12 MiB 批次复制逐字节一致 | ✅ 2026-09-19（`scripts/e2e-p15-bulk.sh`，5 条腿；执行中修掉客户端分片拼接覆盖与复制等待期泵空转两处既有缺陷，见决策 39） |
| P16 | **日志句柄复用**：进程级有界缓存（`open_partition_log` 命中即复用），变更（append/roll/truncate/skip_to/压实/保留）走同一句柄 | 13 次请求跨 6 段只开一次日志；关掉缓存则按请求次数打开；淘汰后可重开且不丢记录；retention/压实经缓存句柄后读取精确、副本逐字节一致；12 MiB 复制期间控制面零投诉 | ✅ 2026-09-19（`scripts/e2e-p16-logcache.sh`，6 条腿；见决策 40） |
| P17 | **基准工具**：`benchmark produce/consume/latency`（本地+远端；值头 4 字节序号做负载下完整性校验；单调 µs 时钟与 nearest-rank 直方图）；执行中修掉 accept 阻塞在 poll 之前的「每请求一 tick」税 | 六条结构腿：计数与偏移区间精确、序号头校验通过、百分位单调、e2e ⊇ produce-ack、**每主题恰好一次 `opened`**（P16 回归护栏）、超限按名拒绝且服务端存活；**吞吐/延迟数字只报告不设门禁**（决策 41） | ✅ 2026-09-22（`scripts/e2e-p17-bench.sh`，6 条腿；矩阵 #22；见决策 41） |
| P18 | **已定位小票收口**：① 真偏移——fetch 应答按**连续偏移段**分帧（空洞/扇出重复各起新帧），本地消费游标按偏移推进（不再按条数）；② serve 命令面——topic 家族（声明入 serve 元数据库、list 为**声明∪磁盘**、delete = 失效缓存后删数据）+ group 家族结构化拒绝；执行中修掉布尔 flag 吞参数的解析 bug | p14 腿 9–11（远端/committed 跨中洞显示真偏移、本地零重复）+ p0 新腿（rf>1 拒绝且说明、声明∪自动创建、删后重产从 0 且 `evicted` 有据、group 解释性拒绝）+ wbtest（分帧 6 条、flag 解析 4 条） | ✅ 2026-09-23（见决策 42） |
| P22 | **单机消费组**：serve 自任协调者（与控制面同一注册表/命令/围栏/清扫）+ 分区枚举 = **声明∪磁盘**（取 max(index)+1，不是数目录）+ compact/retention 地板接最慢消费者 + 成员凭据走 `client_token` 口径 | 自动建题的分区全部被份额覆盖且不重叠、接管续读无缺口、过期世代提交被拒、偏移跨 serve 重启存活、组地板挡 retention、read-only join 被拒且 root 可管理 | ✅ 2026-09-25（`scripts/e2e-p22-serve-groups.sh`，7 条腿；矩阵 #11 补 serve 证据；见决策 46） |
| P23 | **命令面尾巴**：`partition list`（客户端组合，集群/单机同一实现）+ `cluster spu list`（承载计数）+ `profile` 配置档案（resolve_remote 单点解析，档案不是凭据库）+ serve 补 `CMD_OFFSET_INFO` 臂 | partition list 与 cluster offsets 逐分区一致（两种宿主）、自动建题的列表= max(index)+1、档案往返/优先级/移除后拒绝、spu list 承载计数正确 | ✅ 2026-09-25（`scripts/e2e-p23-cli.sh`，5 条腿；见决策 47） |
| P24 | **无重启轮转**：TLS 上下文与 auth.json 按 **mtime 监视**热重载（cert-manager 式换文件即生效；新连接用新材料、在途连接不受影响；坏文件保旧并大声警告）+ 明文+认证启动警告 | 轮转后新 CA 可用、旧 CA 被拒、旧凭据被拒、进程存活且有重载 note；SC 同机制；认证无 TLS 启动即警告 | ✅ 2026-09-25（`scripts/e2e-p24-rotation.sh`，4 条腿；矩阵安全面行；见决策 48） |
| P25 | **批压缩**：DEFLATE 进 `core/codec`（inflate 三块型 + deflate 固定 Huffman/LZ77 + zlib/gzip 容器 + 炸弹上界；外部锚 = Python zlib）；Kafka 连接器按压缩列行动（gzip 解压解析、其余按名拒绝、`?compression=gzip` 产生端可选项） | Python 三容器输出逐字节读回、自往返、校验和对照、炸弹拒绝；我们的压缩器过 Python 解压审判、Python 压缩器过我们解压审判；默认仍为未压缩；未知 codec apply 期拒绝 | ✅ 2026-09-25（`scripts/e2e-p25-compression.sh`，4 条腿 + codec wbtest 9 条；矩阵 #24 补证据；见决策 49） |
| P26 | **ABI v2 标量调用**（设计稿落地）：`mf_op_scalar_abi_version` + `mf_op_eval`（可选成对导出；返回指针、长度走 v1 的 `mf_op_output_len`、失败走 `last_status`/`last_error`）；guest SDK 的 `GuestScalarFn`（显式参数类型）；节点注册表 `scalar-functions.json`（apply 时绑定）；`{"type":"scalar"}` 变换按整批应用 | 沙箱标量跑通且**与 mbel `upper()` 逐字节一致**；未注册名/v1-only 模块在 apply 被拒；类型错与每批上限 fail-closed 无输出；探针补**无导入段检查**与 v2 成对导出 | ✅ 2026-09-25（`scripts/e2e-p26-scalar.sh`，6 条腿 + 真 wasmtime wbtest 9 条；见决策 50） |
| P27 | **编辑器函数集 UI**（P26 收口时议定的六部分范围）：面板（列表/刷新/删除/载入）+ 编辑表单（部署即 CREATE）+ 表达式节点集合下拉（图 → `build_spec` 派生 `functions`）+ 修订漂移标记（部署快照 revision，LIST 前进即提示 re-apply）；资产文档与协议帧全在 `apps/editor-kernel`（ABI 2，页面断言版本） | 门禁 `e2e-p27-editor-functions.sh`（setup/bump/verify，浏览器阶段 agent/人驱动，与 p4-editor 同形不进步表）三腿：面板 CREATE 经 WS 落地、选择器引用入 spec 且 re-apply 换绑 revision 2、历史按当前规则重现（`ALPHA?`）+ 新记录（`BETA?`）；wbtest 11 条（含**长夹具**回归：JSON 应答先于 uleb 试探，短夹具当年全绿是教训） | ✅ 2026-10-05（见决策 52） |
| P19 | **连接器流式语义 + MQTT**：三态 pull（`Records`/`Quiet`/`Exhausted`）+ `pipeline run` 循环（一次性源语义不变）；手写 MQTT 3.1.1 客户端（零依赖、QoS 0 边界、会话复用）；spec 增 mqtt 源/汇 | `e2e-p19-mqtt.sh` 5 腿：订阅源流式交付且**不退出**、线上形状（CONNECT clean / SUBSCRIBE topic）被独立 Python broker 断言、汇发布被 broker 解码、坏 url **apply 期**拒绝 + 死 broker 结构化错误、一次性源一遍退出；wbtest 4 条（URL 解析 / varint 边界 / CONNECT 字节 / PUBLISH 解码含 QoS 1 形状） | ✅ 2026-09-23（见决策 43） |
| P20 | **Kafka 连接器（对接生态对象）**：手写五个锁定版本的非 flexible API（ApiVersions v0 / Metadata v1 / ListOffsets v1 / Produce v3 / Fetch v4）+ RecordBatch v2 构建与解析 + CRC-32C 进 `core/codec`；spec 增 `kafka://` 源/汇 | `e2e-p20-kafka.sh` 5 腿：往返（file→kafka→moonflux）且源保持流式、线上形状（探针/元数据/**CRC 有效的批**/acks=1）被独立 Python broker 断言、`from=latest` 静默与缺失分区拒绝、坏 url/死 broker/旧版本 broker 三种结构化拒绝、一次性源语义不变；wbtest（URL/zigzag 边界/批往返/CRC 篡改/压缩拒绝）；**开发期用 kafka-python 3.0.11 解码我们发出的请求与自建批**（留痕于 ticket 83） | ✅ 2026-09-23（见决策 44；矩阵 #24） |
| P21 | **细粒度授权与审计**：凭据可携带按主题 grants（read/write），`authorize_topic` 作为角色表之后的第二道门（**只收窄、不放大**）；`audit.log` 记拒绝、认证结果与主题生命周期，凭据永不入 | `e2e-p12` 腿 8–10：授权主题双向可用、未授权主题按名拒绝（码 10）、无 grants 凭据行为不变、read-only+write grant 不可放大、审计三断言 + **无凭据泄漏** grep | ✅ 2026-09-25（见决策 45） |

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
- **多路复用已收口**（P5/P13）：三种服务端走同一个 `ConnectionHub`（accept → poll → 分发 → flush），浏览器长连接不再饿死 CLI；此前的"单连接串行"缺口描述已作废（2026-09-19 随 P15 更正，代码见 `apps/cli/hub.mbt`，门禁 `e2e-p5-concurrency.sh` / `e2e-p13-control-plane.sh`）。
- **函数集 UI 的四件套都渲染内核**（P27，决策 52）：面板/表单/选择器/漂移标记里，资产文档构建（`mf_editor_build_function_set`）、CRUD 帧构建与应答解码全在 `apps/editor-kernel`——页面只有渲染与对话状态（`rid → 动作` 路由取代 FIFO，面板与流水线动作并发后按序抵达不再成立）。**表单本地预检只做形状**（集合名复用 `core/spec::valid_topic_name`）；mbel 规则与纯度以节点发布期门禁为唯一权威，编辑器不写第二套。**漂移标记是编辑器侧 advisory**（部署快照 revision vs LIST 现值）；服务端真相是 `topology.json`，门禁断言数据不断言像素。**应答解码的次序是正确性**：JSON 函数集应答必须**先于** apply 应答的 uleb 试探——JSON 首字节（`[` 91 / `{` 123）在长载荷下会通过 uleb 的长度上界，把 LIST 应答误读成部署应答（真页面驱动抓到，短夹具当年全绿）。**UI 不暴露标量函数编写面**：不可信标量函数的路径是 ABI v2 沙箱，不是可信资产面板。


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

- **单机 serve 是同一协调者的另一个宿主**（P22，决策 46）：同一个 `GroupRegistry`、同一组命令、同一围栏与清扫——成员与门禁不应能分辨对端是谁。它独有的两条事实：**分区来源是"声明 ∪ 磁盘"**（produce 自动建题不落声明；磁盘侧取 max(index)+1，`produce --partition 3` 只建 partition-3），**retention 扫磁盘上的一切**（集群节点对每个宿主分区跑，serve 的诚实等价物是 topics/ 下的全部），地板都是 min(自身末端, 组地板)。组客户端的凭据走 `client_token` 口径（--token 优先、环境兜底）——任何"只读环境变量"的凭据路径都是第二个口径，会在认证之下第一句话就被拒。

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
- **轮换是换文件，不是换进程**（P24，决策 48）：证书与凭据表由 mtime 监视热重载——**新连接用新材料；已建立的连接保留其证书与身份**（它们握过手了）；重载失败**保旧并警告**（启动才 fail-fast——把配置笔误变成宕机是最坏的交换）。永远不要让"轮转"变成重启：节点重启才真正打断复制与提交。
- **明文 + 认证必须启动即警告**：凭据走明文线上是操作员不该无意做出的决定——"静默的安全模式本身就是漏洞"的延伸（P12）。
- **OpenSSL 的错误队列是线程局部且粘滞的**：每次 SSL 操作前必须 `ERR_clear_error()`（垫片 `clear_error()` 已就位）。否则前面一次**失败握手**留下的错误会让 `SSL_get_error` 把本次的 WANT_READ 报成 SSL_ERROR_SSL——一条健康连接在"别人失败过之后"就报 `TLS read failed`（P15 门禁踩到：安全门禁先故意试坏证书与无凭据客户端，紧接着的正常 produce 死在读 13 字节帧头上；修法见 `adapters/tls-native/tls_shim.c`）。`SSL_ERROR_ZERO_RETURN` 是**干净的关闭**，不是错误。
- **安全面改变不了数据面对拍**：`e2e-p12-security.sh` 第 7 腿要求 TLS+认证之下复制仍**逐字节一致**。任何"为了安全而稍微改一下数据路径"的想法都要先过这一关。
- **角色表先行，授权收窄（P21）**：`permit(role, cmd)` 仍是解析载荷之前的第一道门；`authorize_topic` 是主题解析后、触碰日志前的第二道门——**grants 只收窄**（read-only 带 write grant 仍不可写），无 grants 的凭据行为与 P12 完全相同，Node/Root 越过 grants（基础设施与操作员不是租户）。
- **审计记什么**：拒绝（角色表/ACL）、认证结果、主题生命周期——**不是每条记录**；`audit.log` 每事件 append 即落盘，写失败必须 stderr 可见；**凭据永不入审计**（p12 腿 10 的 grep 会盯）。WS 死代码教训：**分发路径的副本（哪怕看起来是备用）也必须带同样的认证与鉴权**——已删除的预 hub 路径曾封存一条完整的不认证命令路径。

**P13 事件循环纪律（改 hub / 节点循环 / 复制拨号 / 任何服务端循环前必读；决策依据见 README 决策 36）**

- **一个线程，谁都别等**：三种服务端（`serve` / `spu` / `sc`）是同一个形状——**一次 poll 等 listener 与全部连接**、accept 只在就绪后调用、Service、flush，绝不阻塞在单个对端上。新增服务端入口照抄这个形状。
- **等待要等在 poll 上，一次等完所有事**：listener 与连接**同在一个 poll 集**。先在 `accept()` 里睡一整个 tick 再 poll 连接，等于给每个请求-应答对端征一笔「每请求一 tick」的恒定税——锁步客户端的下一请求总落在 flush 之后的 accept 窗口里（P17 基准实测 ~200 ms，与载荷无关；accept 只在 poll 报告就绪后调用，ticket 75）。
- **等待必须是"步进"，不是"阻塞 + 期限"**。TLS 握手是范例：`adopt` 只 attach（socket 先转非阻塞），每轮 `step_handshake` 推进一步，期限只用来判定"沉默"。**不要**引入"每轮最多等 N 次"这类预算——限制等几次改不了等本身，沉默连接占着 backlog 位置仍会饿死真实客户端（实测：drain 红 / 每轮一次红 / 步进绿）。
- **泵必须贯穿所有等待**（P7 的教训，P13 又被踩到一次）：任何"等对端"的循环都要在等待中服务自己的连接——**包括握手期**。"我们还没有在途请求所以不用泵"是错的推理：你等 WELCOME 的时候，可能正是别人在等你的节点（三节点环状同时拨号 → 互相等死，`sample` 显示 100% 卡在 `SyncLink::connect`）。
- **写不能杀进程**：垫片已进程级忽略 SIGPIPE，因此写向消失的对端返回 `EPIPE`——所有调用点必须把它当"这个连接死了"处理（关连接、继续服务其他人），不得让错误上抛成进程退出。
- **误判与不检测是两种失败**：门禁断言用**症状计数器**（`is offline` / `leader of` / `offering`）而不变，并配一条**反例腿**（真死必须仍判离线）。改调度时两边都要过。
- **在事件循环里加任何新工作前先问**：它会不会让这个循环的一圈变长？一圈的长度就是"最坏情况下多久才轮到别的连接"，而这直接换算成活 heartbeat 与误判离线之间的距离。

**P15 载荷预算纪律（改生产 / 消费 / 复制 / 连接缓冲相关代码前先读；决策依据见 README 决策 39）**

- **压缩只在互操作面，自有协议暂不压**（P25，决策 49）：Kafka 批按其压缩列行动（gzip 解压、其余按名拒绝），解压上界就是 `MAX_BATCH_BYTES`（炸弹上界与预算单一真相合一）。自有 MFS 帧与段文件**保持未压缩**——压自有协议要先重定义预算语义（压前还是压后计），那是显式立项，不是顺手开关。
- **一个预算，全链路**：`@protocol.MAX_BATCH_BYTES`（16 MiB）是"一个批帧最多多少字节"的唯一真相；传输缓冲（`MAX_INBOX/OUTBOX_BYTES`）、消费窗口（`FETCH_WINDOW_BYTES`）、复制窗口（`REPLICATION_WINDOW_BYTES`）都是它的派生，不得再写死第二个数字。**传输不得比协议更严格却不说**：8 MiB 的 inbox 曾把 8.7 MiB 的 produce 变成"connection reset"，服务端日志一行都没有（P15 实测）。
- **生产必须分批**：`Producer::send` 与 `produce --data-dir` 都按 `PRODUCE_CHUNK_BYTES`（4 MiB）切批，偏移在到达序上连续，因此一次发送仍报一个区间。**别把"一个文件一个批"当成用户的错**——那是实现没做预算。批之间**不保证原子**（第 3 批失败时前 2 批已落盘），这是至少一次口径的推论。
- **单条记录先自检**：key/value 超 `MAX_RECORD_BYTES`（4 MiB）在**生产者进程内**按名字拒绝（`record_size_violation`），不要靠服务端的 `ValueTooLarge` 来回告诉调用方。
- **窗口按字节封顶，且"至少一条/一帧"**：`read_bounded` / `read_raw_bounded` 在预算内取窗口；单条记录或单帧超预算时**仍整条/整帧取走**——让读者无法前进比让解码器拒绝更糟。
- **消费以服务端的 `scan_end` 为准**：fetch 应答尾段带"扫描到哪里"（加法段，不升版本）。**不要用"返回条数 < 请求条数"判断读完**：窗口是按字节截断的，规则还可能过滤掉整个窗口，只有服务端知道"没有更多"与"这一窗满了"的区别。
- **fetch 应答一帧 = 一段连续偏移**（P18）：空洞（规则过滤、压实）与扇出重复都各起新帧，帧基址 = 段首真偏移——客户端按帧内 base+序号推导才为真。**别把整个窗口塞进一个帧**：幸存者 0,2,3 曾被打成 0,1,2（实测，compaction 就能触发，不止规则）；本地游标按**末条偏移 + 1** 推进，不按条数（条数 < 跨度时会回头重读）。
- **等对端时要先抽干再泵**：`await_frame` 先读空 socket 再 `pump()`，因为每次泵都值一个 poll tick（50ms）——每 8 KiB 泵一次会让 4 MiB 应答永远超不过 2s 的 peer 期限，复制就一直 `deadline` 且 `hw` 停在 0（P15 实测）。**任何"读一段就服务一次"的循环都要先问：这段读多大？**
- **接收缓冲不逐读拼接**：hub 把一轮的读放进 `pending`，每轮 join 一次；每次读都整体复制 inbox 会让收 17 MiB 变成 19 GB 的 memcpy（P15 实测：20 MiB 生产从 9.5s 降到 2.2s）。

**P16 日志句柄纪律（改日志打开 / 宿主 / 服务端请求路径前先读；决策依据见 README 决策 40）**

- **打开是昂贵的，且是每请求的**：`open_partition_log` 会恢复尾部（扫最后一段，这是恢复语义本身）并重建活动段索引。任何"每请求打开一次"的路径在大段下都是 O(段长)/次——P15 实测的后果是节点把 tick 花在重扫上、错过心跳窗、被控制面判离线。**不要新增绕过缓存的打开路径**：所有日志都从 `open_partition_log` 拿。
- **缓存是唯一持有者**：任何调用点都**不得把句柄存进字段跨调用持有**。这条是淘汰安全的前提——淘汰之所以只是策略而非正确性 bug，正因为被淘汰的句柄一定是没人拿着的那一个。需要长期使用就在每次用时重新 `open_log()`（命中缓存，不贵）。
- **变更走同一句柄 ⇒ 不需要失效**：append / roll / truncate_to_boundary / skip_to / 压实 / 保留全部通过缓存句柄进行，句柄自己维护 `segments`/`next_offset`。若将来出现第二条写入路径（另一个进程、另一个句柄），**失效机制必须先于它存在**——第一条已经来了：serve 的 `topic delete`（P18）经 `log_cache_evict_topic` **先放走句柄再删文件**；新的第二条写入路径必须照此办理。
- **缓存有界**：客户端可以给任意主题名，每个首次触碰都会建日志。上限（`MOONFLUX_LOG_CACHE`，默认 128）与 LRU 淘汰是防 fd 耗尽的手段，不是可选优化。
- **"opened" 行进 stderr**：stdout 是数据流（`consume | cut -f4` 是常态），生命周期诊断一律 stderr；这条同时是门禁的结构计数器（关掉缓存时它应随请求数增长）。
- **不要在进程运行期间改它的数据目录**：缓存（以及"一个进程一个写入者"这条前提）意味着**文件系统上的日志归属于它所在的进程**。门禁要造"新副本"就**先杀掉节点再删目录**（P14 腿 8 原先是"运行中删目录"，P16 让这条假设显形——那个节点内存里的 LEO 还是 5、磁盘上什么都没有，于是它无事可拉、也不是"跨洞追赶"）。
- **`index_saved` 是关于磁盘的事实断言**：新建的段磁盘上没有任何索引，必须从 `false` 起步，只有真写过才置 `true`。相反的值在"每请求重开"的时代看不出来（恢复扫描会把标志重置），一旦句柄长期存活就变成"**索引永远不写**"——P16 抓到这一条，修在 `core/log`（两处建段点）。

**P17 基准纪律（改 benchmark / 门禁断言 / 服务端循环计时相关代码前先读；决策依据见 README 决策 41）**

- **数字只报告，门禁只断言结构**：吞吐与延迟是**报告**（基线、对照、留痕），永远不进 pass/fail——同一批数据不能在空闲笔记本上过、在满载 CI 上红（决策 33 的推论）。门禁可断言的是结构事实：计数与偏移区间、序号头校验、百分位单调、`opened` 计数、按名拒绝。**P16 的回归护栏是 `opened` 计数腿，不是任何毫秒数**。
- **基准记录的值头 4 字节 = 该记录自己的偏移**（大端，后接点填充）：这是负载下最便宜的完整性检查，恰好钉住「应答基址错位」这一类 bug（P15 修过 fetch 侧一个）。`--verify` 在消费侧重导出校验；头不匹配 = 硬失败（退出非零），不是指标。
- **一批一帧**：`--batch-records` × wire 尺寸必须 ≤ `PRODUCE_CHUNK_BYTES`，否则一次 send 是多帧、逐批计时失去意义（命令自己拒绝并说明）。偏移不连续 = 硬失败——基准不打印正确性有问题的报告。
- **计时用垫片的单调微秒时钟**（`mf_cli_now_us`，CLOCK_MONOTONIC）：`@env.now()` 只有毫秒，本地回环的 p50 会圆成 0；间隔不能随 NTP 跳。宿主层专用，内核照旧零时钟。
- **改服务端循环后跑一次 `benchmark latency`**：循环形状的延迟代价（如 accept 税）不会被任何既有门禁抓到——P13 门禁断言的是「不阻塞/不误判」，从不量延迟。这就是基准存在的理由，也是它的日常用途。
- **门禁自己的解析器也是不可信输入的解析器**（P21 实测）：哨兵值（如 `hw=?`）必须在解析处显式拒绝——awk 对 `"?"` 与 `"2"` 做字符串比较且 `"?"` 更大，一条「leader 不可达」的状态行曾被视为 settled，把"还没复制完"变成假通过后立刻字节比对失败。多行状态解析要求数值模式（`hw=[0-9]+`）；单分区精确断言（`[ "$HW" = "3" ]`）天然免疫。**门禁的时序假设同样是不可信输入**（2026-09-27 实测）：端口先开、模式宣告后写（进程要加载凭据表与 TLS 上下文才打印它们），所以"服务已就绪"不能只看端口——断言"日志里出现某行"要用**有界轮询**（`wait_log`，超时仍失败并打印日志），不要在端口一通时 `grep` 一次。开发机赢的竞态，冷 runner 会输（full 首跑 p12/p13 两红，日志里只有 `listening` 一行，距其出现 0.34 ms）。

**P19 连接器纪律（改连接器 / `pipeline run` / 源汇相关代码前先读；决策依据见 README 决策 43）**

- **三态 pull 是契约**：`Records` / `Quiet` / `Exhausted`——流式源用 `Quiet` 表达"此刻没有"，一次性源第二次 pull 必须报 `Exhausted`。不要把"没有"折叠成"耗尽"（订阅源会立刻退出），也不要把"重读"当"新数据"（file 源每 pull 都重读整文件，循环会无限重放）。新增源必须明确自己是哪种，并让 wbtest 钉住第二次 pull 的行为。
- **连接是会话**：流式源/汇 lazy 连接、跨 pull/flush 复用（每 pull 重连会把每个静默窗变成一次握手）；断线 = **结构化错误**，重试是调用者下一轮的事——不要引入静默重连循环（与集群纪律同源：失败是下一个 tick 的问题，不是藏起来的重试）。
- **每批 flush stdout**：被重定向的 stdout 是块缓冲的（P4 教训的重述）——流式 run 不会自己退出，不 flush 的门禁是在断言"没有输出"。任何新 sink 走 stdout 都要 flush。
- **QoS 0 边界写进文档，不写 TODO**：订阅 QoS 0 ⇒ broker 按 min(publish, subscribe) 降级，入站只需处理 QoS 0（防御性 PUBACK 防止 packet id 被读成 payload）；出站 QoS 1（packet id + PUBACK 等待）是明示的后续候选。URL 内嵌凭据会随 spec 落入 `topology.json`——受信网络或 broker 侧 ACL，别把 URL 当保险箱。
- **门禁的对端是独立实现**：MQTT 门禁用 `scripts/mqtt_test_broker.py`（标准库、按规范说话）断言**线上字节**（CONNECT 形状、SUBSCRIBE topic、PUBLISH 内容）——同 `mfs_probe.py` 的精神：断言属于服务端视角，不属于客户端的意愿。

**P20 对接生态纪律（做任何"与外部系统说别人的协议"的客户端前先读；决策依据见 README 决策 44）**

- **对接对象不是对标参考**（AGENTS §7）：Kafka 只在协议客户端这一侧存在——moonflux 自身语义（至少一次、无 leader epoch、默认未提交读）**不被** Kafka 的默认假设改写。新增对接端点时照此定界，别把"大家都这样"带进来。
- **版本锁定 + 连接期探针**：只用非 flexible 编码的固定版本集合；连上先发 ApiVersions 并断言区间，不兼容在**连接期按名报错**（`broker does not support Produce v3 (advertises v0..v2)`）——不要留到解析期变成看不懂的错位。
- **两个实现都归你写时，必须有外部锚点**：客户端与门禁对端同源时，"两边自洽"可以冒充正确。锚点 = 规范定义 + 第三方实现（CRC-32C 用已知检验向量 `"123456789"→0xE3069283` 钉住；开发期用 kafka-python 解码**我们产出的字节**并留痕）。任何新协议客户端都要自带这类锚点。
- **边界写成边界**：无压缩（**按 codec 名**拒绝，如 `compressed batches are not supported (codec gzip)`）、无消费组（偏移是进程内存，重启按 URL 的 `from` 重开）、无幂等/事务（producer_id = −1）、无 TLS/SASL、acks = 1、分区 0（URL 可指）。
- **两个容易致命的格式点**：RecordBatch v2 的 **CRC 从 attributes（偏移 21）起覆盖**——baseOffset/batchLength 不在其内，broker 改写偏移正是靠这个（我们自己解析时也必须照此校验）；**请求与应答一样带 4 字节长度前缀**（少了它 broker 把 api_key 当长度读，表现为连接期挂住——门禁抓到过）。
- **失败即丢会话**：sink/source 任何操作失败都关连接、清状态，下一轮重新解析元数据——"leader 动了就再问一次"，不做静默重连循环（与 P19 的连接器纪律同源）。
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
    ├── cli（produce/consume/serve/pipeline/spu/sc/topic/cluster/group/function-set/operator/benchmark/profile/partition）
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
- [ ] **CI**：推送即跑 `scripts/gates.sh fast`（Linux）；动数据路径前手动跑全量（`gh workflow run ci`，macOS 43 步）。CI 装的是工具链 `latest`，**本地必须 `moon upgrade` 到同版本**（格式器方向相反，见 README 决策 51）
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

- **ABI v2 是加法，不是替代**（P26，决策 50）：v1 的 7 个批导出一个不改；标量导出（`mf_op_scalar_abi_version`/`mf_op_eval`）**可选且成对**——只出一个 = 模块损坏，一个不出 = v1-only 模块照旧（门禁与探针都按这条判）。标量调用**沿用 v1 的返回拆分**：调用返回答案指针、长度走 `mf_op_output_len`、失败走 `last_status`/`last_error`——别发明第三套缓冲协议。**参数类型显式声明并在 guest 内校验**（与 mbel 按调用点推断的差异是文档事实，不是实现细节）；**注册表是节点配置**（`scalar-functions.json`，apply 时解析绑定、未知字段拒绝、未注册名 apply 即拒）；fuel 每调用安装（标量预算与批预算分开），trap → `BudgetExceeded`，其余失败 → 结构化 `EvalError` 且**无半批输出**。**链必须按批应用**（P26 实测：逐记录调用让批算子只拿到单条批、让每批上限永不触发——新加变换节点前先问"它拿到的是批还是条"）。
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

**P14 压实纪律（改压实 / 键语义 / 存储维护命令前先读；决策依据见 README 决策 38）**

- **偏移是身份，压实只删不搬**：帧内偏移是位置语义（基址 + 序号），所以压实以「连续偏移段」为最小重帧单位——被淘汰的记录直接消失，存活的记录**绝不重编号**（消费偏移、水位、截断都建立在偏移上）。
- **读取信任帧基址**：`read` / `read_raw` / 索引重建 / 段汇总 / 截断一律用 `batch.base_offset` 并容忍帧间空洞；`read_raw` 从「首个 base ≥ from 的帧」开始、经 `base_offset` 报告落点；`skip_to` 只给复制追赶用且只许向前。
- **floor 决定一切，且各副本必须用同一个**：只动「段末 ≤ floor」的封存段；leader 的 floor 是 ledger 水位，follower 的是 **leader 最近一次报告的水位**（可滞后 → 删得更少，永不多删）。压实**每个持有分区的节点各自执行**——只做 leader 会在故障切换后复活已删键。
- **每次删除都要报告，幂等是构造性质**：逐段（帧数、记录数、字节）加总计；全存活帧逐字节复制，所以第二遍必然是空报告、一个字节都不动。
- **空段即删除**：整段被淘汰时删除该段（空段是存储拒绝的洞）；日志末端永远是最后一个实际保留帧的末端（尾部空洞不可复原）。
- **键语义的门槛在 CLI 一侧**：`--key-separator` 缺分隔符的行**跳过并告警**（不把整行当值塞进键的位置）；空键记录永不淘汰。

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
| 实用文档 | [docs/user-guide.md](docs/user-guide.md) | 构建 / 快速开始 / CLI 参考 / 集群与消费组 / 安全配置 / 存储运维 / 实战示例 / 故障排查（"怎么用"的唯一位置） |
| 功能矩阵 | [docs/feature-matrix.md](docs/feature-matrix.md) | **能力清单的单一真相**：功能 × 状态 × 证据入口（与兼容性矩阵分工：那里管"对标语义验证状态"） |
| 进度管理 | [docs/project-roadmap.md](docs/project-roadmap.md) | **进度与排期的单一真相**：阶段详情 / 里程碑台账 / 待办（README 只留摘要与链接，决策 37） |
| 进度看板 | [docs/progress-board.md](docs/progress-board.md) | 带日期的进度快照与返工台账（派生视图；真相在 roadmap，每轮收口随提交更新） |
| 生产就绪度评估 | [docs/production-readiness.md](docs/production-readiness.md) | 分级结论 / 事故级缺口 / 最小生产化清单（快照型评估；上线评审的输入） |
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
| 实用文档 | [docs/user-guide.md](docs/user-guide.md) | 操作手册的单一位置：构建 / 快速开始 / CLI / 集群 / 安全 / 运维 / 实战示例 / 排障 |
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
