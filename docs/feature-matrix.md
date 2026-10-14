# moonflux 功能矩阵

> **定位**：面向使用者与集成者——**平台现在能做什么**：按能力域列出的功能清单、每项的状态与可复现的证据入口。**规约依据**：AGENTS.md §10（证据与状态规范）；**边界声明**：本文是**能力清单**的单一真相；「与 Fluvio 对标语义的验证状态」不在本文——见 [`compatibility-matrix.md`](compatibility-matrix.md)（图例的单一真相）；架构原理见 [`architecture.md`](architecture.md)，操作方法见 [`user-guide.md`](user-guide.md)。
>
> **日期**：2026-09-25 · 覆盖 P0–P26 · 图例：✅ 已交付且有门禁证据 · ⚠️ 部分（注明缺口）· ⏳ 未实现（注明触发条件）

## 1. 数据面

| 能力 | 状态 | 说明与证据 |
| :--- | :--- | :--- |
| 分区提交日志（追加 / 偏移分配 / 窗口读） | ✅ | `core/log`；端到端 `scripts/e2e-p0.sh` |
| 崩溃恢复（撕裂尾/损坏帧截断到确认前缀，报告丢弃） | ✅ | `core/log_test`；恢复语义见架构 §5 |
| 多分区（每分区独立日志/水位/选主） | ✅ | `produce/consume/cluster offsets --partition N`；`scripts/e2e-p7-partitions.sh` |
| 段滚动（字节/时长阈值，段边界=帧边界） | ✅ | `MOONFLUX_ROLL_BYTES/_MS`；`scripts/e2e-p8-storage.sh` |
| 稀疏段索引（CRC 校验，疑点回退全扫，逐字节一致） | ✅ | 同上（删 `.idx` 腿） |
| retention（只删整段、floor 以下；结构化拒绝更老读） | ✅ | `MOONFLUX_RETAIN_BYTES/_MS`；`e2e-p8-storage.sh` |
| 键控 compaction（删旧留新，偏移不变） | ✅ | `cluster compact`；键由 `produce --key/--key-separator` 产生；幂等、floor = 提交前缀 ∩ 消费组地板、空键永不淘汰；`scripts/e2e-p14-compaction.sh`（11 腿：8 条语义 + P18 三条**真偏移**——空洞两侧的远端/committed 消费显示幸存者真偏移、本地零重复）+ `core/log_test`（7 条压实测试）；P28 起可后台化（`MOONFLUX_COMPACT_MS`）+ `scripts/e2e-p28-maintenance.sh`（5 腿） |
| **载荷预算**（大记录/大文件全链路） | ✅ | 单一真相 `@protocol.MAX_BATCH_BYTES`（16 MiB）派生所有预算：生产分批 4 MiB（`Producer::send` 与本地 `produce` 同一套，偏移连续）、读取窗口按字节封顶（至少一条/一帧）、fetch 应答带 `scan_end` 加法段、复制窗口 1 MiB、hub 缓冲从协议派生且超限**记日志再关**；单条 key/value 超 4 MiB 由生产者按名拒绝；`scripts/e2e-p15-bulk.sh`（5 腿：20 MiB 逐字节一致 / 偏移精确 / 两处超限的结构化拒绝 / 12 MiB 复制字节一致）+ `core/protocol`/`core/log_test`/`apps/client` 单测 |
| 客户端分片拼接（多段到达的应答） | ✅ | `apps/client` 的 `fill_exact`：每次读只会**追加**到已收前缀之后（此前每次 recv 都写回缓冲区起点，多段到达的应答被静默损坏）；脚本化分片来源的单测 `apps/client/transport_wbtest.mbt` |
| 压缩编解码（P25）：DEFLATE 进 `core/codec`（inflate 三块型 + deflate + zlib/gzip 容器 + 炸弹上界）；Kafka 连接器 gzip 双向（`?compression=gzip` 产生、按压缩列解压读取；snappy/lz4/zstd 按名拒绝）；**自有 MFS 帧仍为未压缩**（显式边界，决策 49） | ✅ | `core/codec_test/deflate_check.mbt`（Python zlib 三容器锚 + 9 条）+ `scripts/e2e-p25-compression.sh`（4 腿双向锚定） |

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
| **metrics + 健康端点**（P35，决策 76） | ✅ | `--metrics-listen`（serve/sc）：`/metrics` 文本计数（闭集标签）、`/healthz` 真读检查；standby 报 503 `lease:failed`；独立端口、无认证但**非回环+认证即警告**；同 poll 集、每轮 ≤4 刮取、250ms 读期限（不让一圈变长）；`uptime_ms` 只报告不被断言（决策 33）。`e2e-p35-metrics.sh` 10 腿 |
| **控制面 HA（active/standby）**（P34，决策 74） | ✅ | `sc --ha`：共享目录上的租约（holder/epoch/expires）、每轮先续约再服务、**写入按 epoch 围栏**、standby 拒绝一切命令并**指名 active 地址**且不跑存活清扫；**无 quorum、无虚拟地址**（边界写明）。门禁 `e2e-p34-sc-ha.sh` 12 腿 |
| **元数据备份/恢复**（P34，决策 74） | ✅ | `cluster metadata show/backup/restore`：可移植 JSON 快照（kind/版本/修订/**CRC-32C**），恢复与存储共用解码器；篡改、回退（除 `--force`）、非快照三类按名拒绝；**CRC 只能发现损坏、不能发现篡改**（写明） |
| **耐久性原语可查**（P34，决策 75） | ✅ | macOS `F_FULLFSYNC`（回落 fsync）、Linux `fsync`；`moonflux doctor` 报告、`e2e-p8-storage.sh` 按平台断言 |
| **全量门禁在 Linux**（P34，决策 75） | ✅ | CI `full-linux` job（ubuntu 跑完整 `scripts/gates.sh`），与 macOS `full` 并列 |
| 集群间镜像 / 多区域 | ❌ **不做**（决策 78） | 缺三样：跨集群偏移映射、目标侧幂等去重、镜像链路认证。**替代**：用 `kafka://`/`mqtt://` 汇把流导出到另一个集群。**触发条件**：真实需求出现时，第一步是"跨集群 produce 幂等性"设计稿 |

## 3. 消费语义

| 能力 | 状态 | 说明与证据 |
| :--- | :--- | :--- |
| 任意 offset 重放 / 最多 N 条 | ✅ | `consume --from N`；`e2e-p0.sh` |
| 提交读开关（`--committed`，应答带水位） | ✅ | `e2e-p4-readmodes.sh`；compatibility-matrix #11 |
| 消费组：join/heartbeat/commit/leave + range 分配（集群与**单机 serve** 同一语义，P22） | ✅ | `consume --group`；`scripts/e2e-p9-groups.sh`（集群）+ `scripts/e2e-p22-serve-groups.sh`（7 腿，单机） |
| 世代围栏（过期提交拒绝，无特权路径） | ✅ | 同上 |
| 托管偏移持久化（跨控制面重启存活） | ✅ | `groups.json` 原子写；同上 |
| 至少一次投递（无缺口；允许重复） | ✅ | 同上（12 生产 vs 18 投递腿） |
| 恰好一次 / 事务 | ❌ **不做**（决策 78） | 当前语义**明示为至少一次**（决策 32，投递无缺口）。EOS 需要事务性 produce + 读已提交 + 幂等序号三件套。**触发条件**：出现"重复不可接受"的消费者时，第一步是把 `producer_id`/epoch 加进协议（显式帧版本决策） |
| 消费组再平衡的增量协商 | ⏳ | 全量 range 再分配（成员集合变化换代） |

## 4. 可编程层

| 能力 | 状态 | 说明与证据 |
| :--- | :--- | :--- |
| mbel 表达式 transforms（消费/回放路径，改规则秒级生效） | ✅ | `apps/transform`；`scripts/e2e-p1-rules.sh` |
| 表达式函数集（版本化资产 + spec 引用 + re-apply 换绑） | ✅ | `function-set` 命令面；`scripts/e2e-p6-functions.sh` |
| 内核正则引擎 + `regex` 过滤变换（P30/T111） | ✅ | `core/regex`（纯计算、全后端；**Thompson NFA 模拟**：线性、无回溯爆炸）；子集明确（`.`/量词/字符类/`^$`/分组/`|`/`\d\w\s`），**不支持**者按名拒绝（`\b`/反向引用/环视/命名组/内联 flag/懒惰量词/Unicode 类）；apply 期编译；`scripts/e2e-p29-examples.sh` 腿 13–15（含拒绝腿） |
| 函数集本地存储路径（`--data-dir`，P30/T107） | ✅ | 本地与远端**共用节点侧同一 handler**（应答逐字节同源）；`--remote` 与 `--data-dir` 互斥按名拒绝；无服务即可 create/list/get/update/apply/run/delete；`scripts/e2e-p6-functions.sh` 第 11 条 |
| 发布期静态检查（语法/未知名/类型/纯度拒绝 `now`） | ✅ | 同上 |
| wasm 算子沙箱（ABI v1，guest 无导入，fail-closed） | ✅ | `scripts/crosscheck-operators.sh`（native vs wasm 字节级一致）；作者面 = [算子作者指南](operator-authoring-guide.md) + 稳定 C ABI 头 `apps/operator-sdk/include/moonflux_operator.h`（P30/T112：每次构建校验头部导出名与 ABI 版本与实现不漂移） |
| 双预算（记录数 + fuel；墙钟仅观测） | ✅ | `core/operator` tier + 宿主 fuel；`operator verify/describe` |
| 算子管理命令面（verify/describe/list） | ✅ | `scripts/e2e-p5-operator.sh` |
| 不可信标量函数进沙箱（ABI v2 标量调用，P26） | ✅ | 可选成对导出 `mf_op_scalar_abi_version`/`mf_op_eval`（返回指针、长度沿 v1 的 output_len）；节点注册表 `scalar-functions.json` + `{"type":"scalar"}` 变换；参数类型显式声明；燃料每调用、fail-closed；**与 mbel `upper()` 逐字节对拍**；`scripts/e2e-p26-scalar.sh`（6 腿）+ 设计稿 §7 落地实录（决策 50） |
| JSON 载荷的字段级读写（`fromJSON`/`get`/`toJSON`/`fromPairs`，P30/T108） | ✅ | 发布期探针按**表达式自己命名的键**构造字符串/数值两种形状（任一成立即发布），字面量坏 JSON、类型冲突与未知名仍被拒；`scripts/e2e-p29-examples.sh` 腿 9–11（含**逐字节恒等往返**）+ `scripts/e2e-p1-rules.sh` 两条拒绝腿 |
| 键控状态（ABI v3 + 状态主题 + 宿主视图，P30/T114） | ✅ | `spec.state.topic` 声明状态主题；宿主启动重放视图（`apps/cli/state.mbt`）、每批按键写回；`{"type":"wasm"}` 模块**导出 v3 成对即自动成为状态节点**；键须 UTF-8、视图上限 `MOONFLUX_STATE_KEYS`（**写前拒绝**）、状态主题≠数据主题、serve 取数路径按名拒绝；`scripts/e2e-p31-state.sh` 8 腿 + 真 wasmtime 适配器测试 + `core/spec`/`core/operator`/SDK 单测 |
| **键控状态**（ABI v3 + 状态主题 + 宿主视图，P30/T114） | ✅ | `spec.state.topic` 声明状态主题；宿主启动重放视图、每批按键写回（`apps/cli/state.mbt`）；`{"type":"wasm"}` 模块**导出 v3 成对即自动成为状态节点**；键须 UTF-8、视图上限 `MOONFLUX_STATE_KEYS`（**写前拒绝**）、状态主题≠数据主题、serve 取数路径按名拒绝；`scripts/e2e-p31-state.sh` 腿 1–8 + 真 wasmtime 适配器测试 |
| **窗口**（tumbling，P30/T114 §5） | ✅ | **窗口即键的形状**：`apps/operator-tumble` 把 key 改写为 `key@窗口起点`（`window_ms` + `time_field`/`key_field`，事件时间可来自记录的 event-time 列、JSON 数字或 **ISO-8601 文本**（`time_format`，必须带 `Z`，亚毫秒按名拒绝）），窗口因此复用键控状态，不需要新 ABI 或宿主支持；**无 idle 触发器、无自动过期、不读时钟**（如实边界）；`e2e-p31-state.sh` 腿 9–10；示例 `examples/sdf/15-word-counter` |
| **宿主侧 HTTP callout**（P30/T115） | ✅ | `{"type":"callout","method":"GET|POST","url":"…{field}…","body":"…","headers":{"Authorization":"Bearer ${VAR}"},"mode":"live|record|replay","cassette":"…","timeout_ms":N}`：`mode` **必填**（确定性是显式选择）；磁带是真实记录的产物，未命中按名拒绝；凭据不进磁带；出站带期限；占位符只认 `{标识符}`；guest 仍无导入。门禁 `scripts/e2e-p32-callout.sh` 9 腿（live 由独立 Python 对端见证、record 产磁带、replay 在**对端已停**时逐字节一致、未命中拒绝、header 出得去且 token 不进磁带、挂住的端点按期限失败、plan 标 `host-io`、无 callout 的管道不回归） |
| 状态示例（word-counter / word-probe / bank-processing / unreal-engine-analytics / car-processing / helsinki-transit / ny-transit / update-state） | ✅ | `examples/sdf/15-word-counter`（每词运行计数 + 续跑）、`16-word-probe`（**两条管道共享同一条状态主题**：计数写、`operator-probe` 只读且**零写入**）、`17-bank-processing`（参考样本 8 事件原样：`operator-bankevents` 1→2 拆 debit/credit + `operator-balance` 按 iban 累加 → Duncan 770 / Lucy 2610；透支标志 + 选流）；门禁 `e2e-p29-examples.sh` 腿 16–22 |
| **窗口关闭的 flush**（P31，决策 69） | ✅ | `apps/operator-topwords`：窗口关闭的判据是**来了一条属于更晚窗口的记录**（水位 = 已见最大事件时间 = 输入的函数，**不读时钟**）；关闭那一刻产出一条汇总（top-N，**并列按词升序**保证确定性），窗口内不产出；迟到记录**按名拒绝**（不静默丢弃）；配套 `apps/operator-keyconst`（全局累加器 = 单键，spec 显式声明）。案例 15 与参考逐字节同形，`e2e-p29-examples.sh` 腿 16 |
| **主题源 / 主题汇**（P31，决策 72–73） | ✅ | `{"type":"topic","name":"T","from":"beginning\|end\|<offset>"}` 作为源（**不复制**：`spec.topic` 必须就是它）、`{"type":"topic","name":"T"}` 作为汇；主题源是**常驻**的（追平 = `Quiet`，从不 `Exhausted`）；**跟随者旁路日志缓存**（另一进程是写入者）；环校验四条 apply 期按名拒绝。`scripts/e2e-p33-topic-relay.sh` 11 腿 |
| **`dedupe` primitive**（P31，决策 71） | ✅ | `apps/operator-dedupe`：每个键的第一条通过（1→0）；**期限 = 键的形状**（`keyfield → tumble → dedupe` ⇒ 每窗去重一次，无窗口 ⇒ 永久，且状态上界如实写明）；无键的链在**宿主**处按名拒绝 |
| 窗口（hopping / 定时器触发 flush） | ⏳ | 未立项：与"算子不读时钟"的红线正面冲突，要做先定义事件时间水位的来源 | 未立项：需要"水位推进才产出"的语义，与"算子不读时钟"的红线冲突，要做就得先定义事件时间水位的来源 |
| **SDF 例子的 native 部署**（决策 86） | ✅ | [`deploy-sdf.sh`](../scripts/deploy-sdf.sh)（start/status/verify/logs/list/stop）+ 部署根（每用例自己的数据目录、共享运行登记 broker、日志、pids、catalog）；三种模式逐行写明（**无静默跳过**）：5 个跑并逐字节验证、3 个跑了但无单一 golden、18 个 deploy-only 带理由；**跨用例主题冲突**（sentence/cars）由"每用例一个数据目录"化解。门禁 `e2e-p41-deploy.sh` 7 腿。指南 [`docs/deployment.md`](deployment.md)。**Docker 部署见下一行** |
| **长跑管道：外部失败是重试不是退出**（决策 94） | ✅ | 长跑 http 轮询器取数失败指数退避重试（1s→…→60s、每次可见、恢复可见）、进程不死；一次性源与 mqtt/kafka 保持"结构化错误→退出"（其探测期拒绝是永久性的）；汇失败**重试同一批**（对端恰收到一次）；死端点不崩（无崩溃循环）；退避确定性无抖动；transform 失败仍退出（不静默跳过）。门禁 `e2e-p47-poll-retry.sh` 4 条。**未做**：一个进程跑整个任务集（N 点位仍是 N 进程） |
| **部署产品化（两段管道 + 单元 + 轮转）**（决策 93） | ✅ | A：直连 https → 恒值判定 → 判决落**主题（键＝点位）**；B：判决主题 → `predicate(verdict=STUCK)` → http 汇外发，**汇也支持 headers/ca**（与源对称）；systemd/launchd 单元 + logrotate；**重启即重放**（换进程同输入 → 零决策、状态不变）。门禁 `e2e-p46-deploy-routing.sh` **4 条**（含对端视角与重启重放）。**边界**：随部署的 webhook URL 是占位符 |
| **TLS 发 SNI**（决策 92） | ✅ | shim 补 SNI（走 `SSL_ctrl`，因为 `SSL_set_tlsext_host_name` 是**宏**不是符号 ✗）；**真实端点直连成功、无需桥**；p45 增"夹具拒收无 SNI 握手"的双向腿。另加 `audit-shell-vars.py` |
| **http 源 https/TLS**（决策 91） | ✅ | `parse_http_url` 认 scheme；spec `source.ca`；**https 缺 ca 校验期按名拒绝**；无隐式系统信任库；`plan` 显示 `(TLS, CA …)`。门禁 `e2e-p45-http-tls.sh` **5 条**（缺 ca／错锚零记录／对 ca 通／对端看到头／名字不匹配被拒）；夹具服务支持 TLS。**未解决**：真实端点仍报 `verify failed (code 20)` ✗，而 openssl CLI 用同一 bundle 通过 ✓（服务器发的是**完整 4 证书链** ✓）——差异在平台 TLS 路径，下一轮本地复现后定位 |
| **http 源请求头**（决策 90） | ✅ | `spec.source.headers` + 写进请求头 + `plan` 标明；名字按 token 校验、值里 CR/LF/NUL **直接拒**（头注入/response splitting ✗）；排序确定（比较器方向由测试钉住）。门禁 `e2e-p44-http-headers.sh` 5 条，**断言对端看到的头**（新夹具服务 `http_fixture_server.py` 按 PostgREST 行为：缺头 404）。**https 仍未支持**（下一步） |
| **时间戳解析：微秒与固定偏移**（决策 89） | ✅ | `iso8601` 校验后截断亚毫秒位、接受 `±HH:MM`/`±HHMM` 固定偏移（仍拒绝裸本地时间与命名时区）；理由 = 令真实 feed 可读，而误差上限 1ms 不可能改变以分钟计的判据。wbtest 16 条（native/wasm），含**真实 feed 的精确形状** |
| **点位恒值（卡值）检测算子**（决策 88） | ✅ | `apps/operator-stuck`（ABI v1+v3，状态在状态主题）；判决 OK/NOTICE/STUCK/NO_DATA，**可疑值（满量程）即刻告警**；事件时间驱动（**不读时钟**）、按水位**去重**（重复轮询零决策）、**断流记录但不切断段**、坏质量样本不作为证据、解除告警有迟滞；状态累积本点位段统计供标定。门禁 `e2e-p43-stuck.sh` **7 条**（抓出并钉住两个真 bug）。**直连缺口**：http 源需加**请求头**与 **TLS**（该接口是 https + `Accept-Profile`） |
| **SDF 例子的 Docker 部署**（决策 87） | ✅ | 多阶段 [`Dockerfile`](../deploy/docker/Dockerfile)（**保留仓库相对布局**：`/opt/moonflux` 是仓库根、带目录引用的 debug 算子模块）+ [`compose.yaml`](../deploy/docker/compose.yaml)（broker / console / 一用例一容器 profile `case` / 集群 profile `cluster`）；非 root、`/data` 卷、healthcheck 打 `/healthz`。**本机无 docker 守护进程**，动态证明在 **CI `docker` 作业**（`MOONFLUX_REQUIRE_DOCKER=1`：构建 + doctor + 目录 spec 视图模型 + broker `/healthz` + **容器内跑真实用例与 expected.txt 逐字节对拍**）；`e2e-p42-docker.sh` 在 gates.sh 里只做静态并**明说动态那半未跑** |
| **控制台面板（任务清单 + 运行表）**（P37-3b，决策 85） | ✅ | 两个内核导出（`mf_editor_task_list`/`mf_editor_run_list`）+ ABI 4；**按 request id 读应答**（`CMD_OK` 不区分命令，靠形状猜就是 P27 教训）；页面两个面板只渲染内核解码的 kind；run-log 按钮读 broker 的 `<task>.run-log`（**浏览器不拥有日志**）。门禁 `e2e-p40-panels.sh` 5 腿：node 用页面产物连真 broker，与 CLI 逐字段对拍。**不做像素门禁** |
| **控制台视图模型（只读拓扑）**（P37-3a，决策 84） | ✅ | 模型由内核导出（`core/pipeline/view.mbt`，纯投影：节点=进程、边=成文规则）；CLI `pipeline view` 与**页面加载的 JS 产物**逐字节一致（门禁在 node 里跑真产物）；编辑器内核 ABI 3；页面按边走序渲染、不可运行画虚线；**不做像素门禁**。**P37-3b 未落地**：任务清单/执行记录面板（需 broker 往返）。门禁 `e2e-p39-console.sh` 5 腿 |
| **运行登记（运行对平台可见）**（P37-2，决策 83） | ✅ | `CMD_RUN_REPORT`（Node 类）+ `CMD_RUN_LIST`（只读），`run list`；`sc` 与 `serve` 同一张表、同一静默窗口；**优雅停止（stopped）与被杀（offline）可区分**且回收不碰 stopped；`<task>.run-log` 主题持有结构化事件，**run id 由 run-log 偏移推导**（不读时钟）；`/metrics` 只出无标签计数。**边界**：无 `--control` 不登记、不写 run-log；运行没有地址（pid+主机名）。门禁 `e2e-p38-run-registration.sh` 7 腿 |
| **多任务（一个节点持一组任务）**（P37-1，决策 81/82） | ✅ | `topology.json` v2 集合 + 一个文档级修订（整份采纳）；`apply` 按名 upsert / `--set` 替换全集 / `delete --name` / `list`；**取数按 topic 选链**；同主题冲突按名拒绝；v1 文档内存迁移；`moonflux_tasks` 无标签 gauge。**集群侧（P37-1b，决策 82）**：控制面持同一份集合文档 + 一个文档级修订，`apply --remote` 三形状 + `delete --remote`（Root-only），节点**整份采纳**，坏文档被拒且保留在跑的。门禁 `e2e-p37-multi-task.sh` 11 腿 + `e2e-p37b-cluster-tasks.sh` 6 腿 |
| **有状态管道的跨节点迁移与续算**（P36，决策 77） | ✅ | 状态 = 键控主题（随复制走）+ **进度标记**（状态主题保留键 = 已折算到的输入偏移）+ **写入走集群**（`--state-remote`，一个分区一个写入者）；`--resume` 从标记续算，**不重不漏**；一次批 = 一次 append。**边界**：副本新鲜度决定正确性、无跨节点键空间再均衡、不是分布式事务——见 [`state-migration.md`](state-migration.md) §3。门禁 `e2e-p36-state-migration.sh` 8 腿 |
| 算子间 shuffle（跨节点键空间再均衡） | ⏳ | 未立项：把键空间在多个运行实例之间切分没有做（管道是进程，跟随所在节点的副本） |
| 沙箱 filter / flat-map 算子（1→0 / 1→N，P29） | ✅ | `apps/operator-filter`（`min_len`/`contains`）与 `apps/operator-flatmap`（`separator`）——过滤与扇出**不能**用 mbel 表达（表达式必须返回字符串），只能落在批算子契约上；配置在 `mf_op_init` 校验（未知键、空分隔符、小数门槛都拒绝）；`scripts/e2e-p29-examples.sh` 腿 2–5 |
| SDF 示例集的 moonflux 应用案例（8 例，P29） | ✅ | `examples/sdf/*`（冻结 spec + 夹具 + expected + 逐例 README）由 `scripts/e2e-p29-examples.sh`（8 腿，字节级对拍）验真；对照表与缺口见 [`sdf-examples-port.md`](sdf-examples-port.md) |
| SDF Studio 式图形化（拓扑视图 / 活指标 / 状态视图） | ⏳ | **未实现，已提案**：三阶段与门禁形态见 [`sdf-studio-exploration.md`](sdf-studio-exploration.md) §4；现有编辑器是 spec 渲染器（`web/editor/` + `apps/editor-kernel`），不画编译后拓扑 |

## 5. 接入与协议

| 能力 | 状态 | 说明与证据 |
| :--- | :--- | :--- |
| 版本化帧协议 v2（HELLO/WELCOME/错误码/rid 回显） | ✅ | `core/client`；`crosscheck-protocol.sh` + 独立 Python 客户端 |
| 单机 TCP 服务（`serve`）与远程读写 | ✅ | `scripts/e2e-p0.sh` |
| serve 单机命令面（P18）：`topic create/list/delete`（声明入 serve 元数据、list = 声明∪自动创建、delete 即删数据且缓存先失效、rf>1 拒绝）；group 命令自 P22 起由 serve 自己协调（P18 的解释性拒绝退役，`e2e-p0` 的 group 腿翻转为协调断言） | ✅ | `scripts/e2e-p0.sh` 的 topic/group 腿 + `scripts/e2e-p22-serve-groups.sh` |
| 连接多路复用（单线程 poll hub，缓冲上限由协议批预算派生） | ✅ | `apps/cli/hub.mbt`（收包按轮 join，超限**报告后**断开）；`scripts/e2e-p5-concurrency.sh`、`scripts/e2e-p15-bulk.sh` 腿 4 |
| 控制面并发服务（`sc` 同 hub；沉默对端不伤害他人） | ✅ | `scripts/e2e-p13-control-plane.sh` |
| WebSocket 网关（同端口，浏览器与 CLI 同协议） | ✅ | `serve --ws`；`scripts/e2e-p4-ws.sh` |
| 连接器：file / stdin / http（source+sink） | ✅ | `apps/connectors`；`scripts/e2e-p1-connectors.sh`；HTTP 源可选轮询（`interval_ms`，P30/T109）：0 = 一次性 GET，正数 = 按时重取，轮询期说 `Quiet` 永不说 `Exhausted` |
| **MQTT 连接器（P19）**：订阅源 + 发布汇（手写 MQTT 3.1.1，零依赖） | ✅ | `mqtt://[user:pass@]host[:port]/topic`；三态 pull（流式源不退出、一次性源语义不变）；QoS 0 边界与 URL 凭据提示见 README 决策 43；`scripts/e2e-p19-mqtt.sh`（5 腿，对端 = 独立 Python broker）；**增量源批量**：`pipeline run` 成为流式循环，消费按批追加 + 变换 + 汇 |
| **Kafka 连接器（P20）**：消费源 + 生产汇（手写五个锁定版本 API + RecordBatch v2 + CRC-32C） | ✅ | `kafka://host:port/topic[?partition=N&from=earliest\|latest\|<offset>]`；连接期版本探针按名拒绝不兼容 broker；无压缩/无消费组/acks=1 等边界见 README 决策 44；开发期经 kafka-python 3.0.11 解码对拍（ticket 83）；`scripts/e2e-p20-kafka.sh`（5 腿，对端 = 独立 Python broker 且**校验收到的批 CRC**） |
| 认证（握手期 CMD_AUTH + 凭据表 + 常数时间比较） | ✅ | `core/auth`；`scripts/e2e-p12-security.sh` |
| **细粒度授权与审计（P21）**：按主题 grants（收窄不放大）+ `audit.log`（拒绝/认证/生命周期，凭据永不入） | ✅ | `core/auth.authorize_topic`；`apps/cli/audit.mbt`；`scripts/e2e-p12-security.sh` 腿 8–10 |
| 授权（闭合权限表，四角色，节点身份独立） | ✅ | 同上（客户端凭据伪造节点命令被拒） |
| TLS 传输（服务端 + 客户端强制校验 + 双向可选） | ✅ | `adapters/tls-native`；`e2e-p12-security.sh`（错 CA/无证书/明文均拒） |
| 节点间安全（复制/控制调用带凭据与 TLS） | ✅ | 同上（TLS+认证下复制逐字节一致） |
| 细粒度 ACL（按主题 grants，只收窄不放宽）/ 审计日志 | ✅ | P21：`e2e-p12-security.sh` 腿 8–10（决策 45） |
| 无重启轮转（P24）：TLS 上下文与凭据表按 mtime 监视热重载（新连接用新材料；在途连接不受影响；坏文件保旧并大声警告）；明文+认证的组合启动即警告 | ✅ | `scripts/e2e-p24-rotation.sh`（4 腿）+ `apps/cli/rotation_wbtest.mbt`（3 条）（决策 48） |
| SASL（自有面挑战-响应认证） | ⏳ | **边界声明而非缺口**（决策 48）：token-over-TLS 覆盖同一威胁；明文端口由警告明示。Kafka 连接器侧的 SASL/TLS 是互操作候选（决策 44 边界） |

## 6. 产品面

| 能力 | 状态 | 说明与证据 |
| :--- | :--- | :--- |
| CLI（单二进制多子命令；数据/集群/运维/管道四族） | ✅ | `apps/cli`；`produce --key/--key-separator`（无分隔符行跳过并告警）、`cluster compact`；命令面盘点 [`cli-roadmap.md`](cli-roadmap.md) |
| 分区观测平表（P23）：`partition list --topic T`（PARTITION/LEADER/REPLICAS/HW/LEO；集群与单机同一实现，与 `cluster offsets` 逐分区一致） | ✅ | `scripts/e2e-p23-cli.sh`（腿 1/5） |
| 节点承载视图（P23）：`cluster spu list`（注册表 + 客户端组合的承载计数；磁盘字节需节点上报，缺位留痕） | ✅ | `scripts/e2e-p23-cli.sh`（腿 4） |
| 连接档案（P23）：`profile add/list/use/remove` + `resolve_remote` 单点解析（显式 --remote 优先；档案不是凭据库——token 条目按名拒绝） | ✅ | `scripts/e2e-p23-cli.sh`（腿 3）+ `apps/cli/profile_wbtest.mbt`（4 条） |
| PipelineSpec v1alpha1（JSON；plan 差异预览 / apply 发布期检查） | ✅ | `core/spec`；`scripts/e2e-p0p.sh` |
| Web 拖拽编辑器（spec-first；同端口 WS；浏览器闭环） | ✅ | `apps/editor-kernel` + `web/editor/`；`scripts/e2e-p4-editor.sh`（浏览器阶段人/agent 驱动） |
| 客户端内核（native + wasm-gc 双后端同一份逻辑） | ✅ | `core/client`；`moon test --target wasm-gc` |
| 编辑器函数集 UI（面板/表单/选择器/漂移标记） | ✅ | `scripts/e2e-p27-editor-functions.sh`（3 腿）+ `apps/editor-kernel` wbtest 11 条；决策 52 |
| 多语言客户端 SDK（Rust/Python/…） | ⏳ | 线协议与第二实现（Python 探针）已证明可复制；SDK 未立项 |
| K8s 部署（CRD 元数据后端 + operator/Helm） | ⏳ | **明确排到最后**（用户裁定，[`project-roadmap.md`](project-roadmap.md) §3）：元数据接口可插拔，本地存储是第一个实现 |
| Benchmark 工具（吞吐/延迟直方图） | ✅ | `benchmark produce/consume/latency`（本地 `--data-dir` + 远端 `--remote`；值头序号做负载下完整性校验；单调 µs 时钟 + nearest-rank 直方图 min/avg/p50/p90/p99/max）；对标 `fluvio benchmark`（其 consumer 基准未发布，本工具补了 consume 与 e2e 可见性）；**数字只报告，门禁只断言结构**（决策 41）；`scripts/e2e-p17-bench.sh`（6 腿） |

## 7. 工程质量面（能力的地基）

| 能力 | 状态 | 说明与证据 |
| :--- | :--- | :--- |
| 一内核多后端（native/wasm/wasm-gc/js 编译矩阵） | ✅ | `supported_targets` fail-fast；`scripts/gates.sh` 四后端步 |
| 确定性重放（内核零时钟/零随机，注入式） | ✅ | AGENTS.md §5 红线；预算语义 fuel（决策 33） |
| 日志句柄复用（进程级有界缓存，淘汰安全） | ✅ | `apps/cli/logcache.mbt`：`open_partition_log` 命中即复用；变更经同一句柄故无需失效；`MOONFLUX_LOG_CACHE` 控制上限与 LRU 淘汰；每次真实打开在 stderr 记一行；`scripts/e2e-p16-logcache.sh`（6 腿） |
| 门禁体系（54 步，含故障注入与对拍） | ✅ | `scripts/gates.sh`；CI 两腿均已绿：`fast` 随推送（Linux，12 步）、`full` 手动（macOS/Linux，54 步） |
| golden vectors + 协议第二实现 | ✅ | `tools/gen_protocol_vectors.py` + `scripts/mfs_probe.py` |
| 可观测性（结构化错误、状态迁移日志、凭据不入日志） | ✅ | 各门禁断言；`RecoveryReport`/`over_time_hint` 等报告位 |
| 元数据存储可插拔（本地文件已实现；CRD 是第二个实现） | ⚠️ | 接口就位（`MetadataStore`），第二个后端随 K8s 立项 |

## 维护规则

- **本文只管"有什么、什么状态、哪里验证"**；对标语义的验证状态在 [`compatibility-matrix.md`](compatibility-matrix.md)，架构解释在 [`architecture.md`](architecture.md)。同一事实出现两处时，以各自单一真相为准并互相链接。
- 新能力落地：先在本文对应域入表（⏳，注明触发条件），取得门禁证据后转 ✅ 并附脚本入口；行内证据一律指向**可运行的脚本或测试**，不写"看起来能跑"。
- 状态图例与 compatibility-matrix 保持一致（✅/⚠️/⏳）。
