# moonflux 路线图与进度

> **定位**：项目的**进度管理**单一真相——分阶段路线图、每阶段的交付物与门禁证据、已达成的里程碑清单与后续排期。**规约依据**：AGENTS.md §2（阶段与门禁，工程纪律口径）；**边界声明**：README 只保留路线图**摘要**并链接到这里（2026-09-17 文档重构，决策 37）；阶段推进的门禁必须可证伪、可复现，"看起来能跑"不计数（AGENTS.md §2）。
>
> **日期**：2026-10-06 · 状态：P0–P28 全部达成 · 门禁全套 44 步绿（native 288 / wasm-gc 185 / 算子 6）· CI 已接线（`fast` Linux 随推送首绿，`full` macOS 手动）

## 1. 阶段路线图（含门禁证据）

| 阶段 | 里程碑 | 交付物 | 门禁（可证伪） |
| :--- | :--- | :--- | :--- |
| **P0**（2–4 周） | **Native 最小闭环** | 内核 codec 子集 + `fs-native` / `net-native` 适配 + 单机最小分区日志 + CLI（produce/consume）+ 文件 Source → topic → stdout Sink 贯通 demo | ✅ 达成（2026-09-15）：`scripts/e2e-p0.sh` 全绿；协议对拍 `scripts/crosscheck-protocol.sh` 全绿 |
| **P0′**（并行） | 产品化地基 | `PipelineSpec` v1alpha1 + CLI `pipeline apply/plan`（声明式管道编译） | ✅ 达成（2026-09-15）：`scripts/e2e-p0p.sh` 全绿；spec 编译为可运行拓扑 + plan 差异预览 |
| **P1** | **连接器与外设** | 连接器框架 + HTTP/文件/MQTT/Kafka Source & Sink + mbel 表达式 transforms（Native 内嵌）；协议服务化与客户端 SDK 雏形 | ✅ 达成（2026-09-15）：`scripts/e2e-p1-connectors.sh`（file/stdin/http 三源 + stdout/http 双汇）与 `scripts/e2e-p1-rules.sh`（不重启 serve 秒级换规则）全绿；MQTT/Kafka 连接器与多路复用按路线图留待后续 |
| **P2** | WASM 算子沙箱 | 算子 guest SDK + 沙箱 ABI + 全算子 + WASM×Native 双后端测试矩阵 | ✅ 达成（2026-09-16）：`scripts/crosscheck-operators.sh` 全绿——同一批 golden records 经 mbel 原生实现与 wasm 算子输出**字节级一致**；trap / 拒绝 / 死循环三类失败 fail-closed；算子已进 `pipeline run` 与 `serve` 两条消费路径 |
| **P3** | 分布式能力 | 复制（ISR 等价语义）+ 选主 + 元数据调和（本地多进程优先） | ✅ 达成（2026-09-16）：`scripts/e2e-p3-{replication,failover,nodes,metadata}.sh` 全绿——HW 只在副本确认后推进、宕机/恢复后水位一致、静默 leader 被替换（提名→自我提升→确认）、旧 leader 回归自降并字节级追平、`kill -9` 后记录数守恒 |
| **P4** | 全平台体验 | 客户端 SDK 完备（native + js 浏览器）、Web 拖拽编辑器、部署形态（**本地单/多进程优先，K8s 可选**） | ✅ 达成（2026-09-17）：真实浏览器里 compose → deploy → run → consume 跑通（`scripts/e2e-p4-editor.sh`，4 条断言；浏览器阶段由 agent/人驱动）；客户端内核化后同一份逻辑在 native 与 wasm-gc 双后端有测试 |
| **P5** | 并发与运维面 | 连接多路复用 + 多分区存储 + 算子管理命令面 | ✅ 达成（2026-09-17）：并发（六腿）、多分区（五腿）、算子管理（四腿）门禁全绿 |
| **P6** | 规则资产 | mbel 函数集：版本化规则资产（`function-set` 命令面）+ spec 按名引用 + 发布期静态检查与纯度策略 | ✅ 达成（2026-09-17）：`scripts/e2e-p6-functions.sh` 10 条断言全绿——部署/列表带单调 revision、引用缺失或越界函数在 apply 被拒、不纯函数体在部署被拒、更新后**必须 re-apply** 才换绑（revision 记入 `topology.json`） |
| **P7** | 多分区复制 | 数据节点多分区宿主 + 逐分区水位/选主 + 分区分辨的运维面 | ✅ 达成（2026-09-17）：`scripts/e2e-p7-partitions.sh` 7 条腿全绿——逐分区复制与确认、**分区隔离**、逐分区换主且不打扰邻居、按分区截断并报告、`cluster status` 逐分区展示；矩阵 #10 转 ✅ |
| **P8** | 存储完备 | 段滚动 + 稀疏索引 + retention（策略注入时钟，安全下界由应用给出） | ✅ 达成（2026-09-17）：`scripts/e2e-p8-storage.sh` 7 条腿全绿——滚动段精确铺满偏移空间、跨段读取一致、删掉全部 `.idx` 读取逐字节不变、retention 只删 floor 以下整段、撕裂尾恰好损失自身段、复制逐段字节一致 |
| **P9** | 消费组与托管偏移 | 控制面即协调者：加入/心跳/提交/离开 + 世代围栏 + range 分配 + 偏移持久化；retention 下界接最慢消费者 | ✅ 达成（2026-09-17）：`scripts/e2e-p9-groups.sh` 7 条腿全绿——份额覆盖且两两不交、成员死亡后接管并**从提交偏移续读**、投递**无缺口**（至少一次）、过期世代提交被拒、偏移跨重启存活、消费者地板挡住 retention |
| **P10** | 持久复制链接 + 预算语义 | 每分区一条长连接（握手一次、每轮一请求一应答）；fuel 强制 / 墙钟观测 | ✅ 达成（2026-09-17）：`e2e-p7-partitions.sh` 的 link 腿（一轮又一轮复制无再次拨号）；`e2e-p5-operator.sh` 语义腿；矩阵 #14 收口（决策 33） |
| **P11** | 控制面资产下发 | pipeline spec 与函数集由控制面持有、数据节点拉取（心跳带修订、文档按需取；节点是缓存不是权威） | ✅ 达成（2026-09-17）：`scripts/e2e-p11-assets.sh` 7 条腿全绿——一次发布两节点采纳、修订不变不重拉、后加入节点自取、控制面消失仍服务、修订**不回退** |
| **P12** | **安全面** | 内核鉴权语义（身份/角色/闭合权限表）+ 握手期认证 + TLS 传输（含节点间）+ 授权门禁 | ✅ 达成（2026-09-17）：`scripts/e2e-p12-security.sh` 7 条腿全绿——无凭据/坏 token 被拒且不入日志、只读能读不能写、客户端身份发节点命令被拒、错 CA/无证书/明文被拒且服务端存活、TLS+认证下复制逐字节一致；矩阵 #17–19（决策 35） |
| **P13** | 控制面改为 poll 驱动 | `sc` 接入 `ConnectionHub`（逐帧分发器 + 步进式 TLS 握手），三种服务端同一循环形状 | ✅ 达成（2026-09-17）：`scripts/e2e-p13-control-plane.sh` 5 条腿全绿——沉默对端不夺走健康节点存活窗且不触发选举、慢客户端不阻塞他人、安全面不回退、真死仍判离线、并发客户端各自正确；执行中修掉环状死锁与 SIGPIPE 两个既有缺陷（决策 36） |

| **P14** | **键语义与键控压实** | `produce --key/--key-separator` + 压实内核（空洞容忍读取、连续偏移段重帧）+ `cluster compact` 命令面 | ✅ 达成（2026-09-18）：`scripts/e2e-p14-compaction.sh` 8 条腿全绿——键全链路可见、压实只删被取代的记录且**偏移逐一保留**、floor 之上不动、第二遍零字节移动、两副本各自压实后**逐段字节一致**、新副本跨空洞追赶；矩阵 #20 |
| **P15** | **载荷预算** | 批次上限单一真相贯穿生产/消费/复制：分批生产（4 MiB）、有界读取窗口（至少一条/一帧）、fetch 应答 `scan_end` 加法段、复制窗口（1 MiB）、传输缓冲从协议派生且超限有日志 | ✅ 达成（2026-09-19）：`scripts/e2e-p15-bulk.sh` 5 条腿全绿——20 MiB 端到端逐字节一致（远超旧 8 MiB 双向上限）、跨分块偏移精确、超限记录按名拒绝且服务端存活、超限帧被**报告**（而非静默重置）且服务端存活、12 MiB 批次复制逐字节一致；执行中修掉客户端分片拼接覆盖与 `await_frame` 泵空转两个既有缺陷（决策 39）；矩阵 #21 |
| **P16** | **日志句柄复用** | 进程级有界日志缓存：`open_partition_log` 命中即复用，变更（append/roll/truncate/skip_to/压实/保留）经同一句柄，故无需失效；`MOONFLUX_LOG_CACHE` 控制上限与淘汰；每次真实打开在 stderr 记一行 | ✅ 达成（2026-09-19）：`scripts/e2e-p16-logcache.sh` 6 条腿全绿——13 请求跨 6 段只开一次；关掉缓存即按请求打开（证明计数有效）；单条缓存淘汰后重开不丢记录；retention 经缓存句柄后地板语义不变；12 MiB 复制期间控制面**零**"判离线/发起选举"投诉且每节点只开一次；压实经缓存句柄掉 14999 条被取代记录、两副本逐字节一致（决策 40） |
| **P17** | **基准工具** | `benchmark produce/consume/latency`（本地+远端；值头序号完整性校验；单调 µs 时钟 + nearest-rank 直方图）；对标 `fluvio benchmark` 并补 consume 与 e2e 可见性两模式（参考系统 consumer 基准未发布） | ✅ 达成（2026-09-22）：`scripts/e2e-p17-bench.sh` 6 条腿全绿（结构断言：计数/区间/单调/`opened` 计数/按名拒绝）；**数字只报告不设门禁**（决策 41）。执行中抓掉一个**既有真缺陷**：`poll_once` 先在 `accept()` 里睡一整个 tick 再 poll 连接——锁步的请求-应答对端**每请求恒定 ~200 ms**（与载荷无关；本地铁环回实测修后 ~202 ms → ~0.1 ms，produce 吞吐 2.4k → 116k recs/s）；顺带修正旧叙事：P15/P16 报告的延迟数字里有相当一部分是这笔 tick 税（ticket 75）。提速浮出并修掉两条门禁自身的时序竞态（p8 启动期 retention 扫描、p14 follower floor 滞后一轮）；矩阵 #22 |
| **P18** | **已定位小票收口** | ① 真偏移：fetch 应答按连续偏移段分帧（`ReplyPacker`；空洞/扇出各起新帧）+ 游标按偏移推进；② serve 命令面：topic 家族（delete = evict 后删数据）+ group 解释性拒绝 + 布尔 flag 解析修复 | ✅ 达成（2026-09-23）：`e2e-p14-compaction.sh` 腿 9–11 + `e2e-p0.sh` topic/group 腿全绿——**实测发现 compaction 空洞今天就触发偏移错位**（幸存者 0,2,3 → 打成 0,1,2）与本地跨洞重复读（2,3,2,3），三路（远端/committed/本地）全真；布尔 flag 曾吞掉下一个参数使 `--committed --remote X` 静默变本地消费（决策 42） |
| **P19** | **连接器流式语义 + MQTT** | 三态 pull（`Records`/`Quiet`/`Exhausted`）+ `pipeline run` 流式循环（一次性源语义逐字节不变）；手写 MQTT 3.1.1 客户端（零依赖、QoS 0 边界、会话复用）+ spec 的 mqtt 源/汇 | ✅ 达成（2026-09-23）：`scripts/e2e-p19-mqtt.sh` 5 腿全绿——订阅源流式交付三条消息**且不退出**、CONNECT/SUBSCRIBE 形状由独立 Python broker 在线上断言、汇发布被解码、坏 url apply 期拒绝且死 broker 是结构化错误、一次性源仍一遍退出；Kafka 协议面大，单独立票（决策 43） |
| **P20** | **Kafka 连接器（对接生态对象）** | 手写五个锁定非 flexible 版本 API（ApiVersions v0/Metadata v1/ListOffsets v1/Produce v3/Fetch v4）+ RecordBatch v2 构建/解析 + CRC-32C 进 `core/codec`；spec 增 `kafka://` 源/汇；连接期版本探针 | ✅ 达成（2026-09-23）：`scripts/e2e-p20-kafka.sh` 5 腿全绿——往返（file→kafka→moonflux）且源保持流式、线上形状被**独立 Python broker** 断言且**校验批 CRC-32C**、from=latest 静默、坏 url/死 broker/旧版本 broker 三类结构化拒绝；**开发期 kafka-python 3.0.11 解码我们发出的请求与自建批**（ticket 83）；定位说明：Kafka 是互操作端点不是对标参考（决策 44；矩阵 #24） |
| **P21** | **细粒度授权与审计** | 凭据可携带按主题 grants（read/write），`authorize_topic` 为角色表之后的第二道门（只收窄不放大）；`audit.log` 记拒绝/认证/主题生命周期，凭据永不入 | ✅ 达成（2026-09-25）：`e2e-p12` 腿 8–10 全绿——授权主题双向可用、未授权按名拒绝（码 10）、无 grants 凭据行为不变、read-only+write grant 不可放大、审计断言 + 无凭据泄漏 grep；顺带删除预 hub 死代码（内含完整不认证命令路径）（决策 45） |
| **P22** | **单机消费组** | serve 自任协调者（与控制面同一 `GroupRegistry`/命令/围栏/清扫）；分区枚举 = 声明∪磁盘（磁盘取 max(index)+1）；compact/retention 地板 = min(自身末端, 组地板)；serve 的 retention 扫描扩为磁盘上的一切；组客户端凭据走 `client_token` 口径；`CMD_LEADER` 重归类为数据面读 | ✅ 达成（2026-09-25）：`scripts/e2e-p22-serve-groups.sh` 7 条腿全绿——自动建题的分区全部被份额覆盖且不重叠、投递无缺口、幸存者接管、过期世代提交被拒、偏移跨 serve 重启存活、组地板挡 retention、认证之下 read-only 拒绝；执行中发现并修复组客户端路径只读环境变量的凭据缺口（集群侧同样存在，认证门禁此前未覆盖成员路径）（决策 46）；矩阵 #11 补 serve 证据 |
| **P23** | **命令面尾巴** | `partition list`（客户端组合，集群/单机同一实现）+ `cluster spu list`（承载计数；磁盘字节需节点上报留痕）+ `profile` 配置档案（resolve_remote 单点解析、档案不是凭据库）+ serve 补 `CMD_OFFSET_INFO` 臂 + usage() 补齐 | ✅ 达成（2026-09-25）：`scripts/e2e-p23-cli.sh` 5 条腿全绿——partition list 与 cluster offsets 逐分区一致（两种宿主）、自动建题列表 = max(index)+1、档案往返/优先级/移除拒绝、spu list 承载计数正确；`topic add-partition` 明确不做（放置调和事件，非命令面尾巴）（决策 47） |
| **P24** | **无重启轮转** | TLS 上下文与 auth.json 按 mtime 监视热重载（新连接用新材料、在途不受影响、坏文件保旧警告）+ 明文+认证启动警告 + SASL 边界声明 | ✅ 达成（2026-09-25）：`scripts/e2e-p24-rotation.sh` 4 腿全绿——轮转后新 CA 可用/旧 CA 被拒/旧凭据被拒/进程存活、SC 同机制、明文警告；`rotation_wbtest` 3 条（决策 48） |
| **P25** | **批压缩** | DEFLATE 进 `core/codec`（inflate 三块型 + deflate 固定 Huffman/LZ77 + zlib/gzip 容器 + 炸弹上界，外部锚 = Python zlib 金标语料）；Kafka 连接器 gzip 双向 + 按名拒绝；自有协议压缩保持显式边界 | ✅ 达成（2026-09-25）：`scripts/e2e-p25-compression.sh` 4 腿全绿（双向外部锚定 + 默认不变 + apply 期拒绝）+ codec wbtest 9 条；执行中自抓三个自身 bug（漏 BTYPE、块头次序、容器校验和覆盖错对象）（决策 49） |
| **P26** | **ABI v2 标量调用** | 设计稿落地（可选成对导出、返回指针 + v1 的 output_len/last_status 拆分、guest SDK 显式参数类型、节点注册表 apply 绑定、`{"type":"scalar"}` 变换）；链改整批应用（逐记录调用曾让批算子只拿单条批、上限永不触发）；探针补无导入段检查 | ✅ 达成（2026-09-25）：`scripts/e2e-p26-scalar.sh` 6 腿全绿（与 mbel 逐字节对拍、四类结构化拒绝）+ 真 wasmtime wbtest 9 条；设计稿 §7 落地实录（决策 50） |
| **P27** | **编辑器函数集 UI** | 六部分议定范围（P26 收口时）：面板（列表/刷新/删除/载入）+ 编辑表单（部署即 CREATE）+ 表达式节点集合下拉（图 → `build_spec` 派生 `functions`）+ 修订漂移标记（部署快照 revision、LIST 前进即提示 re-apply，编辑器侧 advisory）+ 不含标量函数编写面 + 门禁形态；资产文档与协议帧全在 `apps/editor-kernel`（ABI 2） | ✅ 达成（2026-10-05）：`scripts/e2e-p27-editor-functions.sh` 三腿全绿（面板 CREATE 经 WS 落地、引用入 spec 且 re-apply 换绑 revision 2、历史按当前规则重现）+ wbtest 11 条；执行中修掉 apply 应答试探误读长 JSON 应答的真缺陷（决策 52） |
| **P28** | **存储维护调度** | 后台压实加入既有维护节拍：`MOONFLUX_COMPACT_MS` 节拍即开关（默认关）、`MOONFLUX_COMPACT_MIN_DIRTY_BYTES` 透传内核 `min_dirty_bytes`、枚举与 floor 与 retention 同源（serve 抽 `serve_maintenance_targets`，spu 按 topic/partition 记节拍与 50ms tick 解耦）；顺带把 `decode_log_frames.py` 升到 P18 真偏移语义 | ✅ 达成（2026-10-06）：`scripts/e2e-p28-maintenance.sh` 5 腿全绿（默认关 / 收敛到每键最新且偏移不变 / 组地板挡压实 / 手动命令不变 / spu 同语义非 tick 同频）；进 gates.sh 步表 43→44（决策 53） |
> **为什么 Native 先行**（2026-09-15 修订，README 决策 3）：数据源（Source）与数据汇（Sink）需要**独立的外部读写能力**——网络 / 文件 / 协议 / MQ / 硬件直采，**WASM 沙箱不能自主 IO**；连接器与数据面是第一梯队能力，因此承载它们的 Native 先行。WASM 保留为"数据路径内算子沙箱"（P2 落地）；**内核全后端可编译的纪律由 CI 矩阵从第一天保持**。
>
> **K8s 与阶段的关系**：P0–P3 **不依赖 K8s**，全部在本地单机/多进程推进与验收；K8s 仅是部署目标之一，只贡献元数据后端（CRD）与生命周期自动化。数据面、复制、选主、元数据调和是**任何部署模型都需要**的架构能力（AGENTS.md §1.2）。

## 2. 里程碑台账

- [x] `git init` 与远端仓库（如需）（远端待配）
- [x] P0 达成：内核 codec/protocol/log + fs/net-native 适配 + CLI + 端到端 demo（2026-09-15）
- [x] P0′ 达成：PipelineSpec v1alpha1 + pipeline plan/apply/run（2026-09-15）
- [x] P1 达成：mbel 表达式 transforms 接入消费路径 + 版本化协议服务化 + 连接器框架（2026-09-15）
- [x] P2 达成：算子 guest SDK + ABI v1 + wasmtime 进程内宿主 + native-vs-wasm 对拍门禁（2026-09-16）
- [x] P3 达成：复制（LRS 等价语义）+ 选主 + 元数据调和，本地多进程最小集群（`sc` + `spu`×2），故障注入门禁全绿（2026-09-16）
- [x] P4 达成：客户端内核化 + 同端口 WS 网关 + Web 拖拽编辑器（真实浏览器闭环）（2026-09-17）
- [x] P5 达成：连接多路复用 + 多分区存储与数据路径 + 算子管理命令面（2026-09-17）
- [x] P6 达成：mbel 函数集作为版本化规则资产，`scripts/e2e-p6-functions.sh` 10 条断言全绿（2026-09-17）
- [x] P7 达成：多分区复制，`scripts/e2e-p7-partitions.sh` 7 条腿全绿，矩阵 #10 转 ✅（2026-09-17）
- [x] P8 达成：存储完备（多段日志 + 稀疏索引 + 滚动与 retention + `cluster segments`），`scripts/e2e-p8-storage.sh` 7 条腿全绿，矩阵 #10 完全收口（2026-09-17）
- [x] P9 达成：消费组与托管偏移，`scripts/e2e-p9-groups.sh` 7 条腿全绿，矩阵 #11 收口（2026-09-17）
- [x] P3 类小项收口：预算语义（fuel 强制 / 墙钟观测），矩阵 #14 ⚠️ → ✅（2026-09-17，决策 33）
- [x] P10 达成：持久复制链接与预算语义（2026-09-17，决策 33 同期）
- [x] P11 达成：控制面资产下发，`scripts/e2e-p11-assets.sh` 7 条腿全绿（2026-09-17）
- [x] P12 达成：安全面，`scripts/e2e-p12-security.sh` 7 条腿全绿，矩阵 #17–19（2026-09-17，决策 35）
- [x] P13 达成：控制面改为 poll 驱动，`scripts/e2e-p13-control-plane.sh` 5 条腿全绿；修掉环状死锁与 SIGPIPE 两个既有缺陷（2026-09-17，决策 36）
- [x] P14 达成：键语义与键控压实（`produce --key/--key-separator`、`cluster compact`、空洞容忍读取），`scripts/e2e-p14-compaction.sh` 8 条腿全绿，矩阵 #20（2026-09-18）
- [x] P15 达成：载荷预算贯穿数据路径，`scripts/e2e-p15-bulk.sh` 5 条腿全绿；修掉客户端分片拼接覆盖（`fill_exact`）与复制等待期泵空转（`await_frame`）两个既有缺陷，矩阵 #21（2026-09-19，决策 39）
- [x] P16 达成：进程级有界日志句柄缓存，`scripts/e2e-p16-logcache.sh` 6 条腿全绿；12 MiB 复制由"永远 deadline、hw 停在 0"变为 1 秒收敛（2026-09-19，决策 40）
- [x] P17 达成：基准工具（produce/consume/latency，本地+远端），`scripts/e2e-p17-bench.sh` 6 条腿全绿；执行中抓掉 accept 先于 poll 的「每请求一 tick」税（本地铁环回 ~202 ms → ~0.1 ms，ticket 75）与两条门禁时序竞态（2026-09-22，决策 41）
- [x] P18 达成：已定位小票收口——fetch 应答按连续段分帧（**实测发现 compaction 的空洞今天就触发**：幸存者 0,2,3 被打成 0,1,2；本地消费按条数推进跨洞重复读）+ serve 的 topic 家族（delete 即删数据、缓存先失效——P16 预言的第二写入路径第一条实例）与 group 解释性拒绝 + 布尔 flag 解析修复；p14 腿 9–11 + p0 新腿（2026-09-23，决策 42）
- [x] P19 达成：连接器流式语义（三态 pull + `pipeline run` 循环）+ MQTT 3.1.1 连接器（零依赖手写，QoS 0 边界），`scripts/e2e-p19-mqtt.sh` 5 腿全绿（对端 = 独立 Python broker）（2026-09-23，决策 43）
- [x] P20 达成：Kafka 连接器（手写五 API + RecordBatch v2 + CRC-32C；开发期第三方解码对拍），`scripts/e2e-p20-kafka.sh` 5 腿全绿（2026-09-23，决策 44）
- [x] P21 达成：细粒度授权（按主题 grants，收窄不放大）+ 审计日志（拒绝/认证/生命周期，凭据永不入），`e2e-p12` 腿 8–10 全绿；顺带删除预 hub 死代码的不认证命令路径（2026-09-25，决策 45）
- [x] P22 达成：单机消费组——serve 自任协调者（同一注册表/命令/围栏），分区枚举 = 声明∪磁盘，地板接最慢消费者，`scripts/e2e-p22-serve-groups.sh` 7 腿全绿；顺带修复组客户端凭据只读环境变量的缺口（`--token` 成员在认证下第一句话被拒）与 `CMD_LEADER` 的归类（能读数据的人必须能找到数据）（2026-09-25，决策 46）
- [x] P23 达成：命令面尾巴——`partition list` / `cluster spu list` / `profile` 三条挂账命令清账，serve 补 `CMD_OFFSET_INFO` 臂（`cluster offsets` 对 serve 此前从未通过）；`scripts/e2e-p23-cli.sh` 5 腿全绿（2026-09-25，决策 47）
- [x] P24 达成：无重启轮转——TLS 上下文与凭据表 mtime 监视热重载（换文件即生效、坏文件保旧、明文+认证启动警告），SASL 给出边界声明；`scripts/e2e-p24-rotation.sh` 4 腿全绿（2026-09-25，决策 48）
- [x] P25 达成：批压缩——DEFLATE 编解码进 core/codec（Python zlib 三容器金标语料锚定 + 炸弹上界）+ Kafka 连接器 gzip 双向；`scripts/e2e-p25-compression.sh` 4 腿全绿（2026-09-25，决策 49）
- [x] P26 达成：ABI v2 标量调用（触发条件成立）——沙箱标量函数端到端、与 mbel 逐字节对拍、四类结构化拒绝；顺带修链的整批应用与探针的无导入段检查（2026-09-25，决策 50）
- [x] 远端仓库达成（2026-09-25，用户提供 `github.com/dimon-83/moonflux`）：94 笔提交全历史推送
- [x] **CI 接线达成（2026-09-27）**：工作流落在 [`.github/workflows/ci.yml`](../.github/workflows/ci.yml)（`.scratch/moonflux-ci/` 那份暂存副本已退休——线上有了权威副本，留着就是第二真相）。`fast`（12 步）随推送在 **ubuntu-latest** 首绿（run `36324100660`，1 分 41 秒，**本仓首次 Linux 验证**：四后端编译 + 双测试套件）；`full`（43 步 E2E）手动触发于 macos-14，2026-09-27 **首次跑满 43/43**（run `36325414560`，5 分 13 秒）。接线过程抓出五件事（registry 索引前置、wasmtime 与 `st_mtimespec` 两处 macOS-only、两个门禁假绿）与工具链版本政策，见决策 51 与看板返工台账第 11 条；full 首跑另暴露两处**门禁自身的启动时序假设**（p12/p13），修法与证据见同表第 13 条
- [x] **P27 达成：编辑器函数集 UI（2026-10-05，决策 52）**——面板/表单/选择器/漂移标记四件套，资产文档与协议帧全在 `apps/editor-kernel`（ABI 2，页面断言版本）；表单预检只做形状（mbel 规则与纯度以节点发布期门禁为唯一权威）；UI 不暴露标量函数编写面。门禁 `scripts/e2e-p27-editor-functions.sh` 三腿全绿（面板 CREATE 经 WS 落地、引用入 spec 且 re-apply 换绑 revision 2、历史按当前规则重现 `ALPHA?` + 新记录 `BETA?`）+ wbtest 11 条；执行中修掉 `mf_editor_feed` 的 apply 应答试探误读长 JSON 应答的真缺陷（真页面驱动抓到；教训：**夹具必须覆盖真实载荷的长度级别**）。tickets 97–99
- [x] **P28 达成：存储维护调度（2026-10-06，决策 53）**——后台压实加入既有维护节拍（立项盘点修正：retention 自 P9 起已周期化，缺口只有压实）；节拍即开关、重写门槛透传内核、floor 单一真相；`scripts/e2e-p28-maintenance.sh` 5 腿全绿并进步表（44 步）；`decode_log_frames.py` 升级为真偏移输出。tickets 100–102
- [x] 生成项目规约 [`AGENTS.md`](../AGENTS.md)（2026-09-15）；随代码结构落地更新（2026-09-16 补 §10 文档规范）

## 3. 待办与排期

- [x] ~~compaction~~ **已达成**（2026-09-18，P14：键语义启用 + 键控压实落地）
- [x] ~~**CI 接线**~~ **已达成**（2026-09-27，决策 51）：`fast` 随推送（Linux，首绿 run `36324100660`）+ `full` 手动（macOS）；**工具链政策**：CI 装 `latest`（CDN 拒版本化 URL，钉不住），仓库采纳该版本格式，本地须 `moon upgrade` 同步
- [ ] **下一梯队**（按优先级）：多语言客户端 SDK（待需求触发）；~~编辑器函数集 UI~~ **已达成**（2026-10-05，P27，见决策 52）；~~ABI v2 实现~~ **已达成**（2026-09-25，P26，见决策 50）
- [x] ~~P15 后续：每请求重开日志~~ **已达成**（2026-09-19，P16：进程级有界缓存，见决策 40 与 `scripts/e2e-p16-logcache.sh`）
- [x] ~~P16 后续 ①：benchmark 工具~~ **已达成**（2026-09-22，P17：`benchmark produce/consume/latency` + `scripts/e2e-p17-bench.sh`，见决策 41；执行中抓掉 accept 先于 poll 的每请求一 tick 税，ticket 75）
- [x] ~~P16 后续 ②：带过滤表达式的逐记录偏移~~ **已达成并扩大**（2026-09-23，P18：不止规则——**compaction 的空洞今天就触发**同样错位；修法为 fetch 应答按连续偏移段分帧，远端/committed/本地三路全真，见决策 42）
- [x] ~~门禁卫生（原 P16 后续 ③）~~ **已达成**（2026-09-19）：p7/p14 清理改为**按各自固定端口兜底杀**——命令替换重启的节点被 init 收养，pid 再寻址不到而端口仍可；固定端口检查保持清理的特异性（P14 曾连续两次漏掉一个 spu），收尾后 `pgrep cli.exe` 为空
- [ ] **K8s 部署形态（CRD 元数据后端 + operator）明确排到最后**（2026-09-17，用户裁定并留痕）：AGENTS §1.2 本就把 K8s 定为可选、与本地单二进制并列，且元数据接口可插拔（CRD 是第二个实现而非重写，推迟无锁定成本）；更关键的是它的门禁需要真实集群才可证伪，而本项目要求门禁可复现——把弱门禁排在强门禁之后。真需要时第一步也不是 CRD：清单 + PVC 跑文件后端即可上 K8s
- [x] ~~MQTT 连接器~~ **已达成**（2026-09-23，P19：三态 pull + 手写 MQTT 3.1.1 客户端 + `e2e-p19-mqtt.sh`，决策 43）
- [x] ~~Kafka 连接器~~ **已达成**（2026-09-23，P20：五个锁定版本 API + RecordBatch v2 + CRC-32C；外部锚点验证，决策 44）
- [ ] 多语言客户端 SDK（线协议已有第二实现证明可复制；SDK 未立项）

**不做清单**（永久或条件触发，防无意带入）：见 AGENTS.md §9；安全面的边界（无 ACL/SASL/审计）见 README 决策 35。

## 维护规则

- 阶段状态变化：先过**门禁**，再同步本文 §1/§2，并同步 AGENTS.md §2 的阶段表（两处口径一致）。
- 新里程碑立项时在 `.scratch/moonflux-pN/issues/` 建 ticket 集（编号跨阶段全局连续），关账后回填本文。
- 排期变更（尤其是"推迟/不做"）必须**留痕**：写明日期、依据与裁定者。
