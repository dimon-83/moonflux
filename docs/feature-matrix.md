# moonflux 功能矩阵

> **定位**：面向使用者与集成者——**平台现在能做什么**：按能力域列出的功能清单、每项的状态与可复现的证据入口。**规约依据**：AGENTS.md §10（证据与状态规范）；**边界声明**：本文是**能力清单**的单一真相；「与 Fluvio 对标语义的验证状态」不在本文——见 [`compatibility-matrix.md`](compatibility-matrix.md)（图例的单一真相）；架构原理见 [`architecture.md`](architecture.md)，操作方法见 [`user-guide.md`](user-guide.md)。
>
> **日期**：2026-09-23 · 覆盖 P0–P19 · 图例：✅ 已交付且有门禁证据 · ⚠️ 部分（注明缺口）· ⏳ 未实现（注明触发条件）

## 1. 数据面

| 能力 | 状态 | 说明与证据 |
| :--- | :--- | :--- |
| 分区提交日志（追加 / 偏移分配 / 窗口读） | ✅ | `core/log`；端到端 `scripts/e2e-p0.sh` |
| 崩溃恢复（撕裂尾/损坏帧截断到确认前缀，报告丢弃） | ✅ | `core/log_test`；恢复语义见架构 §5 |
| 多分区（每分区独立日志/水位/选主） | ✅ | `produce/consume/cluster offsets --partition N`；`scripts/e2e-p7-partitions.sh` |
| 段滚动（字节/时长阈值，段边界=帧边界） | ✅ | `MOONFLUX_ROLL_BYTES/_MS`；`scripts/e2e-p8-storage.sh` |
| 稀疏段索引（CRC 校验，疑点回退全扫，逐字节一致） | ✅ | 同上（删 `.idx` 腿） |
| retention（只删整段、floor 以下；结构化拒绝更老读） | ✅ | `MOONFLUX_RETAIN_BYTES/_MS`；`e2e-p8-storage.sh` |
| 键控 compaction（删旧留新，偏移不变） | ✅ | `cluster compact`；键由 `produce --key/--key-separator` 产生；幂等、floor = 提交前缀 ∩ 消费组地板、空键永不淘汰；`scripts/e2e-p14-compaction.sh`（11 腿：8 条语义 + P18 三条**真偏移**——空洞两侧的远端/committed 消费显示幸存者真偏移、本地零重复）+ `core/log_test`（7 条压实测试） |
| **载荷预算**（大记录/大文件全链路） | ✅ | 单一真相 `@protocol.MAX_BATCH_BYTES`（16 MiB）派生所有预算：生产分批 4 MiB（`Producer::send` 与本地 `produce` 同一套，偏移连续）、读取窗口按字节封顶（至少一条/一帧）、fetch 应答带 `scan_end` 加法段、复制窗口 1 MiB、hub 缓冲从协议派生且超限**记日志再关**；单条 key/value 超 4 MiB 由生产者按名拒绝；`scripts/e2e-p15-bulk.sh`（5 腿：20 MiB 逐字节一致 / 偏移精确 / 两处超限的结构化拒绝 / 12 MiB 复制字节一致）+ `core/protocol`/`core/log_test`/`apps/client` 单测 |
| 客户端分片拼接（多段到达的应答） | ✅ | `apps/client` 的 `fill_exact`：每次读只会**追加**到已收前缀之后（此前每次 recv 都写回缓冲区起点，多段到达的应答被静默损坏）；脚本化分片来源的单测 `apps/client/transport_wbtest.mbt` |
| 压缩编解码（gzip/snappy 等批压缩） | ⏳ | 未立项；帧载荷现为未压缩批 |

## 2. 复制与集群

| 能力 | 状态 | 说明与证据 |
| :--- | :--- | :--- |
| follower 拉取复制（原始帧搬运，字节一致） | ✅ | `core/replica`；`scripts/e2e-p3-replication.sh` |
| 高水位 `HW = min(LEO)`（只前进；未确认不提交读） | ✅ | `core/replica_test`；读模式 `--committed`（`e2e-p4-readmodes.sh`） |
| LRS（滞后副本失投票权，追上回归） | ✅ | 同上；语义对标见 compatibility-matrix #15 |
| 集中提名 + 候选自我提升 + 旧 leader 自降 | ✅ | `scripts/e2e-p3-failover.sh`（含 `kill -9` 记录守恒） |
| 分区级隔离与逐分区换主 | ✅ | `scripts/e2e-p7-partitions.sh`（隔离/换主腿） |
| 分歧回归：新 leader LEO 唯一权威，按帧边界截断并报告 | ✅ | `truncate_to_boundary`；`e2e-p7-partitions.sh` 重归腿 |
| 节点存活推导（3s 静默即离线）+ 离线清扫 | ✅ | `sc` 日志 `is offline`；`e2e-p3-nodes.sh` |
| 元数据持久化与调和（放置/提名/主题声明） | ✅ | `scripts/e2e-p3-metadata.sh` |
| 控制面资产下发（管道+函数集；修订不回退；失败保留在跑管道） | ✅ | `scripts/e2e-p11-assets.sh` |
| 集群间镜像 / 多区域 | ⏳ | 未立项 |

## 3. 消费语义

| 能力 | 状态 | 说明与证据 |
| :--- | :--- | :--- |
| 任意 offset 重放 / 最多 N 条 | ✅ | `consume --from N`；`e2e-p0.sh` |
| 提交读开关（`--committed`，应答带水位） | ✅ | `e2e-p4-readmodes.sh`；compatibility-matrix #11 |
| 消费组：join/heartbeat/commit/leave + range 分配 | ✅ | `consume --group`；`scripts/e2e-p9-groups.sh` |
| 世代围栏（过期提交拒绝，无特权路径） | ✅ | 同上 |
| 托管偏移持久化（跨控制面重启存活） | ✅ | `groups.json` 原子写；同上 |
| 至少一次投递（无缺口；允许重复） | ✅ | 同上（12 生产 vs 18 投递腿） |
| 恰好一次 / 事务 | ⏳ | 未立项；当前语义明示为至少一次 |
| 消费组再平衡的增量协商 | ⏳ | 全量 range 再分配（成员集合变化换代） |

## 4. 可编程层

| 能力 | 状态 | 说明与证据 |
| :--- | :--- | :--- |
| mbel 表达式 transforms（消费/回放路径，改规则秒级生效） | ✅ | `apps/transform`；`scripts/e2e-p1-rules.sh` |
| 表达式函数集（版本化资产 + spec 引用 + re-apply 换绑） | ✅ | `function-set` 命令面；`scripts/e2e-p6-functions.sh` |
| 发布期静态检查（语法/未知名/类型/纯度拒绝 `now`） | ✅ | 同上 |
| wasm 算子沙箱（ABI v1，guest 无导入，fail-closed） | ✅ | `scripts/crosscheck-operators.sh`（native vs wasm 字节级一致） |
| 双预算（记录数 + fuel；墙钟仅观测） | ✅ | `core/operator` tier + 宿主 fuel；`operator verify/describe` |
| 算子管理命令面（verify/describe/list） | ✅ | `scripts/e2e-p5-operator.sh` |
| 不可信标量函数进沙箱（ABI v2 标量调用） | ⏳ | **只设计未实现**：`docs/operator-abi-v2-scalar.md`；触发条件=多租户提交函数的需求 |
| 有状态算子 / 算子间 shuffle | ⏳ | 未立项（报告 §5 范围外） |

## 5. 接入与协议

| 能力 | 状态 | 说明与证据 |
| :--- | :--- | :--- |
| 版本化帧协议 v2（HELLO/WELCOME/错误码/rid 回显） | ✅ | `core/client`；`crosscheck-protocol.sh` + 独立 Python 客户端 |
| 单机 TCP 服务（`serve`）与远程读写 | ✅ | `scripts/e2e-p0.sh` |
| serve 单机命令面（P18）：`topic create/list/delete`（声明入 serve 元数据、list = 声明∪自动创建、delete 即删数据且缓存先失效、rf>1 拒绝）+ group 家族解释性拒绝 | ✅ | `scripts/e2e-p0.sh` 的 topic/group 腿 |
| 连接多路复用（单线程 poll hub，缓冲上限由协议批预算派生） | ✅ | `apps/cli/hub.mbt`（收包按轮 join，超限**报告后**断开）；`scripts/e2e-p5-concurrency.sh`、`scripts/e2e-p15-bulk.sh` 腿 4 |
| 控制面并发服务（`sc` 同 hub；沉默对端不伤害他人） | ✅ | `scripts/e2e-p13-control-plane.sh` |
| WebSocket 网关（同端口，浏览器与 CLI 同协议） | ✅ | `serve --ws`；`scripts/e2e-p4-ws.sh` |
| 连接器：file / stdin / http（source+sink） | ✅ | `apps/connectors`；`scripts/e2e-p1-connectors.sh` |
| **MQTT 连接器（P19）**：订阅源 + 发布汇（手写 MQTT 3.1.1，零依赖） | ✅ | `mqtt://[user:pass@]host[:port]/topic`；三态 pull（流式源不退出、一次性源语义不变）；QoS 0 边界与 URL 凭据提示见 README 决策 43；`scripts/e2e-p19-mqtt.sh`（5 腿，对端 = 独立 Python broker）；**增量源批量**：`pipeline run` 成为流式循环，消费按批追加 + 变换 + 汇 |
| 连接器：MQTT / Kafka | ⏳ | 框架已留位（P1 收尾项），未实现 |
| 认证（握手期 CMD_AUTH + 凭据表 + 常数时间比较） | ✅ | `core/auth`；`scripts/e2e-p12-security.sh` |
| 授权（闭合权限表，四角色，节点身份独立） | ✅ | 同上（客户端凭据伪造节点命令被拒） |
| TLS 传输（服务端 + 客户端强制校验 + 双向可选） | ✅ | `adapters/tls-native`；`e2e-p12-security.sh`（错 CA/无证书/明文均拒） |
| 节点间安全（复制/控制调用带凭据与 TLS） | ✅ | 同上（TLS+认证下复制逐字节一致） |
| 细粒度 ACL（按主题/分区授权）/ SASL / 证书轮转 / 审计日志 | ⏳ | 安全面后续候选（README 决策 35 已声明边界） |

## 6. 产品面

| 能力 | 状态 | 说明与证据 |
| :--- | :--- | :--- |
| CLI（单二进制多子命令；数据/集群/运维/管道四族） | ✅ | `apps/cli`；`produce --key/--key-separator`（无分隔符行跳过并告警）、`cluster compact`；命令面盘点 [`cli-roadmap.md`](cli-roadmap.md) |
| PipelineSpec v1alpha1（JSON；plan 差异预览 / apply 发布期检查） | ✅ | `core/spec`；`scripts/e2e-p0p.sh` |
| Web 拖拽编辑器（spec-first；同端口 WS；浏览器闭环） | ✅ | `apps/editor-kernel` + `web/editor/`；`scripts/e2e-p4-editor.sh`（浏览器阶段人/agent 驱动） |
| 客户端内核（native + wasm-gc 双后端同一份逻辑） | ✅ | `core/client`；`moon test --target wasm-gc` |
| 编辑器函数集 UI | ⏳ | spec 可携带引用；UI 待需求 |
| 多语言客户端 SDK（Rust/Python/…） | ⏳ | 线协议与第二实现（Python 探针）已证明可复制；SDK 未立项 |
| K8s 部署（CRD 元数据后端 + operator/Helm） | ⏳ | **明确排到最后**（用户裁定，[`project-roadmap.md`](project-roadmap.md) §3）：元数据接口可插拔，本地存储是第一个实现 |
| Benchmark 工具（吞吐/延迟直方图） | ✅ | `benchmark produce/consume/latency`（本地 `--data-dir` + 远端 `--remote`；值头序号做负载下完整性校验；单调 µs 时钟 + nearest-rank 直方图 min/avg/p50/p90/p99/max）；对标 `fluvio benchmark`（其 consumer 基准未发布，本工具补了 consume 与 e2e 可见性）；**数字只报告，门禁只断言结构**（决策 41）；`scripts/e2e-p17-bench.sh`（6 腿） |

## 7. 工程质量面（能力的地基）

| 能力 | 状态 | 说明与证据 |
| :--- | :--- | :--- |
| 一内核多后端（native/wasm/wasm-gc/js 编译矩阵） | ✅ | `supported_targets` fail-fast；`scripts/gates.sh` 四后端步 |
| 确定性重放（内核零时钟/零随机，注入式） | ✅ | AGENTS.md §5 红线；预算语义 fuel（决策 33） |
| 日志句柄复用（进程级有界缓存，淘汰安全） | ✅ | `apps/cli/logcache.mbt`：`open_partition_log` 命中即复用；变更经同一句柄故无需失效；`MOONFLUX_LOG_CACHE` 控制上限与 LRU 淘汰；每次真实打开在 stderr 记一行；`scripts/e2e-p16-logcache.sh`（6 腿） |
| 门禁体系（36 步，含故障注入与对拍） | ✅ | `scripts/gates.sh` |
| golden vectors + 协议第二实现 | ✅ | `tools/gen_protocol_vectors.py` + `scripts/mfs_probe.py` |
| 可观测性（结构化错误、状态迁移日志、凭据不入日志） | ✅ | 各门禁断言；`RecoveryReport`/`over_time_hint` 等报告位 |
| 元数据存储可插拔（本地文件已实现；CRD 是第二个实现） | ⚠️ | 接口就位（`MetadataStore`），第二个后端随 K8s 立项 |

## 维护规则

- **本文只管"有什么、什么状态、哪里验证"**；对标语义的验证状态在 [`compatibility-matrix.md`](compatibility-matrix.md)，架构解释在 [`architecture.md`](architecture.md)。同一事实出现两处时，以各自单一真相为准并互相链接。
- 新能力落地：先在本文对应域入表（⏳，注明触发条件），取得门禁证据后转 ✅ 并附脚本入口；行内证据一律指向**可运行的脚本或测试**，不写"看起来能跑"。
- 状态图例与 compatibility-matrix 保持一致（✅/⚠️/⏳）。
