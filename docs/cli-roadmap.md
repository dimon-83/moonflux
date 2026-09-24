# moonflux CLI 命令工具规划（对标 Fluvio CLI）

> 定位：CLI 是 moonflux 的产品化入口，也是 PipelineSpec 的权威编译/执行器（README 决策 5 spec-first）。
> 本文档盘点现状、对标 Fluvio CLI 命令面（评估报告第二章各节实录）、给出缺口的分阶段映射与设计原则。
> **边界声明**：本规划不改变当前 P2（WASM 算子沙箱）进行中的工作；各命令批次在实际启动时按惯例立 ticket（`.scratch/moonflux-p{N}/issues/`）。

## 1. 现状（已交付，P0–P12 门禁全绿）

单二进制多子命令形态（`apps/cli`，AGENTS.md §1.2 的"单程序多子命令"设计），构建产物
`_build/native/debug/build/apps/cli/cli.exe`（`moon build --target native` 的产物；门禁脚本默认测它，
`MOONFLUX_EXE` 可覆盖——**别**把门禁指向一个恰好存在的 release 二进制，那曾让一次门禁跑在上一轮的构建上）：

| 命令 | 语义 | 门禁证据 |
| :--- | :--- | :--- |
| `produce --topic T --file F [--data-dir D \| --remote host:port]` | 文件源 → 本地日志追加 / 经 `serve` 远端追加 | `scripts/e2e-p0.sh` |
| `consume --topic T [--from N] [--data-dir D \| --remote host:port]` | 打印 `offset\ttimestamp\tkey\tvalue`；任意 offset 重放 | `scripts/e2e-p0.sh`（`--from 7`） |
| `serve --data-dir D --listen host:port` | TCP 帧协议服务（v2 握手 + 每请求热规则重载） | `scripts/e2e-p0.sh`、`scripts/e2e-p1-rules.sh` |
| `pipeline plan -f spec.json` | spec 编译 + 线上差异预览（不落盘） | `scripts/e2e-p0p.sh` |
| `pipeline apply -f spec.json` | 发布期静态检查（mbel）+ 落盘 `topology.json` | `scripts/e2e-p0p.sh`、`scripts/e2e-p1-rules.sh` |
| `pipeline run [--spec P] [--name N]` | 单进程执行编译拓扑（source → topic → transform → sink） | `scripts/e2e-p0p.sh`、`scripts/e2e-p1-connectors.sh` |

- 实现文件：`apps/cli/{main,produce,consume,serve,pipeline,rules,store}.mbt`；数据布局 `<data-dir>/topics/<topic>/partition-0.log`，应用状态 `<data-dir>/topology.json`。
- 已知现状缺陷见 §5 勘误（含 `usage()` 帮助文本滞后）。

### 1.1 安全面 flags（P12，决策 35）

凭据与传输是**进程级**配置，落在每个需要出网/收网的命令上，语义一致：

| flag | 作用 | 环境变量回退 |
| :--- | :--- | :--- |
| `--token T` | 该连接展示的凭据（角色由服务端的凭据表决定，客户端不声明角色） | `MOONFLUX_TOKEN` |
| `--tls-ca P` | 信任锚；**出现即启用 TLS**（没有"--tls 开关"式的旗标：没有锚就没有可默认的信任） | `MOONFLUX_TLS_CA` |
| `--tls-cert P` / `--tls-key P` | 本进程的证书与私钥（双向 TLS 时服务端要求）；节点进程同时用它们**服务**自己的端口 | `MOONFLUX_TLS_CERT` / `MOONFLUX_TLS_KEY` |
| `--tls-require-client` | **仅服务端**（`serve` / `spu` / `sc`）：要求对端出示证书 | — |

要点：① 客户端**永远校验证书**（`VERIFY_PEER` + 主机名钉住）——"装了 CA 却不校验"比不做 TLS 更糟；② 没有凭据/CA 时行为与 P11 完全一致，但启动**明说**当前模式；③ 节点进程（`spu`/`sc`）用同一套 flags 既服务又出站，`PeerLink{token, tls}` 贯穿所有节点间调用；④ 消费组成员（`consume --group`）从环境读同一组变量——成员可能是 CLI 调用，也可能是被环境配置的进程，两者都要能连上 TLS 控制面。

## 2. 对标基准：Fluvio CLI 命令面（评估报告 §2.x 实录）

> 在线索引：[Fluvio CLI overview](https://www.fluvio.io/docs/fluvio/cli/overview)（cluster start / topic create·list / produce / consume / partition list / cluster spu list / SmartModule / benchmark 等）；本节各命令语义以评估报告对应章节（离线、已核验）为准。

| 命令族 | 代表命令 | 报告依据 |
| :--- | :--- | :--- |
| 集群生命周期 | `fluvio cluster start --local/--k8`、`check --fix`、`status`、`shutdown`、`delete`、`upgrade`、`resume`、`diagnostics` | §2.10.1–2.10.3 |
| Topic 管理 | `fluvio topic create/list/describe/delete`、`add-partition -c N`、`--dedup` | §2.2.2–2.2.4、§2.7 |
| 分区观测 | `fluvio partition list`（LEADER/REPLICAS/SIZE/HW/LEO/LSR 列） | §2.2.3 |
| 生产 | `fluvio produce <topic>`（stdin 逐行 / `-f` / `--raw` / `--key-separator` / `--delivery-semantic`） | §2.3.4 |
| 消费 | `fluvio consume`（起点 `-B/-H/-T/--start`、终点 `--end`、`-p/-A`、输出 `-O/-F`、`-d` 读完退出） | §2.4.5 |
| 消费偏移 | `fluvio consumer list/delete`（托管偏移，无消费组） | §2.4.4 |
| SmartModule | `fluvio smartmodule create/list/watch/delete/test`；收/发挂算子 `--smartmodule/--transforms` | §2.6.2、§2.6.4 |
| Profile | `fluvio profile add/switch/rename/delete/sync/export`（`~/.fluvio/config`） | §2.10.5 |
| SPU/SPG | `fluvio cluster spu register/unregister/list`；`spg create` | §2.10.4 |
| 镜像 | `fluvio remote register/export`、`home connect`、`topic create --mirror` | §2.8.2 |
| 基准工具 | `fluvio benchmark`（producer 吞吐 + 延迟直方图） | §2.12 |
| Pipeline（moonflux 先行项） | `fluvio pipeline apply/plan/delete -f`（报告建议形态，参考系统尚无） | §6.3.3 路线 2 |
| 插件机制 | `fluvio-<cmd>` 外部插件（hub/cdk 即经此路径） | `docs/fluvio-reference-guide.md` §2、报告 §2.1 |

**差异说明**：Pipeline 命令族是 moonflux 的先手（P0′ 已交付 `apply/plan/run`，报告 §6.3.3 路线 2 只给出 apply/plan/delete 三形态）；其余命令族 moonflux 均处空白或雏形，见 §3。

## 3. 缺口 → 分阶段映射

### 3.1 现在可做（无新内核依赖，可与 P2 并行）

| 命令 | 对标 | 前置 / 说明 |
| :--- | :--- | :--- |
| `topic create/list/describe/delete` | §2.2.3、§2.2.4 | 无（现有 `<data-dir>/topics/` 布局即可）；命名校验复用 `core/spec.valid_topic_name`；list/describe 先输出本地可见字段（分区数=1、段大小、水位），retention/compression 等字段待 P3 元数据 |
| `consume` 对标补齐 | §2.4.5 | 起点/终点 `-B/--beginning`、`-H/--head N`、`-T/--tail N`、`--end N`（现仅 `--from N`）；输出 `-O json/table`、`-F` 模板（现为固定 TSV）；`-d` 读完退出在本地路径即现行为 |
| `produce` 输入形态补齐 | §2.3.4 | stdin 逐行（`produce <topic>` 无 `-f` 时）、`--key-separator`、`--raw`；connectors 已有 stdin/file source 可复用 |
| `profile` 连接配置 | §2.10.5 | 多环境 profile（本地文件，如 `~/.moonflux/config` 或 data-dir 内），替代每次裸传 `--remote`；`sync k8\|local` 属远期 |
| `pipeline delete` | §6.3.3 路线 2 | 删除 topology.json / 取消执行；补齐报告建议的 apply/plan/**delete** 三形态 |
| `codec` 协议工具 | §4.4.2（P1 行"codec 校验/编解码 CLI"） | 帧/批解码与校验子命令；能力已在 `apps/vectortool` 内，提升为正式子命令即对标完成 |
| 帮助与用法 | —（自身质量项） | `usage()` 补 `pipeline` 与各命令帮助（§5 勘误 1）、增加 `--help` 非错误退出 |

### 3.2 P2 伴随项（WASM 算子沙箱）

- `pipeline plan/run` 与 spec 校验对 wasm transform 的呈现（capability 标记 `wasm-p2`）——**已含于 P2 ticket 17**；
- 算子管理雏形：`operator create/list/delete`（对标 `fluvio smartmodule create/list/[watch/]delete`，§2.6.4）——**本规划新增提议，尚未立 ticket**；命名与注册目录约定随 P2 收尾确定；
- 消费挂算子：对标 `fluvio consume --smartmodule`（§2.6.2，SPU fetch 路径执行）——与 README 决策 10（规则作用于消费路径）同构，wasm 算子作为 mbel 表达式并列的 transform 类型。

### 3.3 P3（控制面就绪后）

- `partition list`：对标 §2.2.3 列集；依赖多分区与元数据（compatibility-matrix 行 10）；
- `topic add-partition -c N`：对标 §2.2.4；依赖多分区；
- `consumer` 托管偏移管理（list/delete）：对标 §2.4.4；moonflux 偏移托管语义本身属 P3（compatibility-matrix 行 11）；
- `cluster`/`spu` 命令族：随"单程序多子命令 all-in-one / sc / spu"拆分落地（AGENTS.md §1.2），本地多进程即最小集群；对标 §2.10.1–2.10.4，其中 K8s 专有项随 P4 可选部署；
- `benchmark`：对标 §2.12（producer 基准先行，consumer 基准参考系统亦未发布）；
- （远期、未排期）镜像命令族：对标 §2.8.2，依赖多集群能力。

#### 3.3.1 落地回填（2026-09-16，P3 达成）

已交付（命令面与证据）：
- `topic create --name T [--partitions N] [--replication-factor R] --remote SC` / `topic list` /
  `topic delete --name T`：声明式主题管理，写元数据 store（`<sc data-dir>/metadata.json`，
  版本单调、重名与非法名写入前拒绝）；门禁 `scripts/e2e-p3-metadata.sh`。
- `cluster nodes --remote SC`：在线节点（id:role、地址、LEO）；
  `cluster status --remote SC`：节点 + 主题 + **每分区 leader/副本数/水位**（水位向 leader 问，
  不是 SC 的记忆）；`cluster leader --topic T` / `cluster offsets --topic T`：放置与水位查询。
- `spu --id A --listen host:port [--data-dir D] [--sc SC]` 与 `sc --listen host:port`：
  节点形态（`serve` 保留为全在一体形态，向后兼容）。

仍未交付（属 P4 或后续）：
- `partition list`（多分区存储未落地，见 compatibility-matrix #10）、`cluster spu list` 的
  完整字段（磁盘/主题数等）、`consumer` 托管偏移（矩阵 #11 另一半）、
  `profile`（配置档案）、SmartModule/算子管理命令族。

#### 3.3.3 落地回填（2026-09-22，P17 达成）

- `benchmark produce|consume|latency --topic T [--data-dir D | --remote host:port]`：
  吞吐/延迟基线工具，对标 `fluvio benchmark`（报告 §2.12：producer 吞吞吐 + 延迟直方图；
  参考系统 consumer 基准隐藏未发布，本工具补了 consume 与 produce→consume 可见性两模式）。
  produce 报吞吐 + 逐批 ack 直方图（`--records/--record-size/--batch-records`，一批一帧），
  consume 抽干至 `scan_end` 且 `--verify` 校验值头序号（= 偏移，负载下完整性检查），latency
  报 produce-ack 与 e2e 两组直方图（`--samples`）。**数字只报告、门禁只断言结构**（README
  决策 41）；门禁 `scripts/e2e-p17-bench.sh`（6 腿）。执行中抓掉 accept 先于 poll 的
  「每请求一 tick」税（ticket 75，`apps/cli/hub.mbt`）。

#### 3.3.2 落地回填（2026-09-18，P14 达成）

- `produce --key K` / `--key-separator S`：键进入记录（互斥；无分隔符行跳过并在 stderr 汇总）；
  对标报告 §2.3.4；门禁 `scripts/e2e-p14-compaction.sh` 腿 1。
- `cluster compact --topic T [--partition N] --remote <node>`：一次键控压实，逐段报告
  （帧数前/后、删除记录数、字节前/后）+ 总计；对**持有该分区的每个节点**各执行一次
  （副本必须一致），floor 由节点自己算（提交前缀 ∩ 消费组地板）；门禁同上（腿 2–8）。
- 更早的 P5/P6/P8 命令面（`operator` / `function-set` 覆写、`cluster segments`）见各自阶段的
  ticket 与 `scripts/e2e-p5-operator.sh`、`e2e-p6-functions.sh`、`e2e-p8-storage.sh`。

#### 3.3.4 落地回填（2026-09-23，P18 达成）

- `topic create/list/delete --remote <serve>`：单机命令面落地（此前 `unknown command 15`）——
  声明入 serve 自己的元数据库（与函数集同库同版本），list 为**声明 ∪ 自动创建**的并集，
  delete 即删数据且日志缓存先失效（P16 预言的第二写入路径第一条实例）；rf>1 结构化拒绝。
- `group describe/list --remote <serve>`：解释性拒绝（协调者是控制面，先例 = 数据节点拒绝
  放置命令）；serve 上做完整协调需要放置与 leader 地址发现，未立项（独立小票候选）。
- 语义修正：fetch 应答按连续偏移段分帧——压实/规则过滤的空洞之后逐记录偏移曾整体错位；
  布尔 flag（`--committed`/`--follow`/`--verify`/`--ws`/`--tls-require-client`）不再吞掉
  下一个参数（`--committed --remote X` 曾静默变本地消费）。

#### 3.3.5 落地回填（2026-09-23，P19 达成）

- MQTT 连接器：spec 源/汇支持 `{"type":"mqtt","url":"mqtt://[user:pass@]host[:port]/topic"}`
  ——源为**订阅**（`pipeline run` 首拉建连订阅，流式运行不自行退出；三态 pull 的
  `Quiet`/`Exhausted` 语义见 AGENTS §2 P19 块），汇为**发布**；QoS 0 边界与 URL 凭据提示
  见 README 决策 43。对标：参考系统的生产连接器在外仓（本仓只有框架）——MQTT 客户端是自建
  （零依赖，手写 3.1.1）。门禁 `scripts/e2e-p19-mqtt.sh`（5 腿，对端 = `scripts/mqtt_test_broker.py`）。
- `pipeline run` 从「一次 pull 一次性执行」变为支持流式源的循环（一次性源语义不变）——
  cli-roadmap §1 的 `pipeline run` 行按此口径理解。
- Kafka 连接器仍未交付（协议面远大于 MQTT，单独立票）。

### 3.4 P4（全平台体验）

- CLI 契约稳定化：与 native + wasm 客户端 SDK 对齐（README 能力对标表"客户端 SDK"行）；
- 编辑器 spec-first 闭环：UI 是 spec 渲染器（决策 5），CLI 仍是 spec 的权威执行器——编辑器的部署/回滚直接复用 `pipeline apply/plan` 语义；
- 插件机制（`moonflux-<cmd>` 对标 `fluvio-<cmd>`，`docs/fluvio-reference-guide.md` §2）：可选，视生态需要。

## 4. 设计原则

1. **spec 单一真相**：声明式命令一律围绕 PipelineSpec（决策 5/7/9），CLI 不引入第二真相；
2. **本地优先**：每条命令的本地闭环（`--data-dir`）先于远端/集群形态；远端与集群命令在控制面就绪后接管（决策 9 执行形态的延伸，AGENTS.md §1.2）；
3. **可证伪门禁**：每个命令批次附 e2e 脚本（`scripts/e2e-*.sh` 既有模式）与负例（非法输入被拒绝、退出码非零）；
4. **留痕**：对标语义逐条引用报告章节；本规划决策记入 README「关键决策记录」13；新增对标语义按需入 `docs/compatibility-matrix.md`；
5. **不越界**：不改变 P2 进行中工作；批次启动时立 ticket 并回填本文档状态。

## 5. 勘误（本次盘点发现，未修，供后续 ticket）

| # | 发现 | 位置 | 状态（2026-09-16） |
| :-- | :--- | :--- | :--- |
| 1 | `usage()` 帮助文本仍为 P0 版：缺 `pipeline` 命令 | `apps/cli/main.mbt` 的 `usage()` | ✅ 已修（并随 P3 补齐 `spu`/`sc`/`cluster`/`topic`） |
| 2 | 待办行"P1 启动"未勾选，与路线图"P1 达成"不一致 | `README.md`「待办（下一步）」 | ✅ 已修（待办区随 P1/P2/P3 达成逐步更新） |
| 3 | 生成接口滞后：工作区 `spec.mbt` 已含 `HttpSource`/`StdinSource`/`HttpSink`，`.mbti` 未随 `moon info` 重生成 | `core/spec/pkg.generated.mbti` | ✅ 已修（`moon info` 已重生成并入库） |

---

*维护规则：命令批次启动/交付时更新 §1 与 §3 的状态；本规划随阶段演进，重大调整同步 README 决策记录。*
