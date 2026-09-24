# moonflux 进度看板（快照）

> **定位**：**带日期的进度快照与看板**——已完成 / 待办 / 优先级 / 阻塞 / 返工一页可读，并附功能点简介。**规约依据**：AGENTS.md §10（文档规范）；**边界声明**：本文是**派生视图**，不是单一真相——阶段详情与排期的真相在 [`project-roadmap.md`](project-roadmap.md)，能力清单在 [`feature-matrix.md`](feature-matrix.md)，对标语义在 [`compatibility-matrix.md`](compatibility-matrix.md)，决策依据在 README「关键决策记录」（现 1–42），工作项在 `.scratch/moonflux-p{N}/issues/`（编号 01–77 全局连续）。快照日期见下；每轮里程碑收口时随提交更新。

**快照日期**：2026-09-23 · 状态：**P0–P20 全部达成** · 门禁全套 **37 步绿**（native 239 / wasm-gc 162 / 算子 6）

---

## 看板

### ✅ 已完成（19 个里程碑全部收口，证据可复现）

| 里程碑 | 功能点一句话 | 收口 | 证据 |
| :--- | :--- | :--- | :--- |
| P0 / P0′ | Native 最小闭环 + PipelineSpec：文件源 → topic → stdout；spec 编译为进程拓扑 | 09-15 | `e2e-p0.sh` · `e2e-p0p.sh` |
| P1 | 连接器与外设：HTTP/文件/stdin 源汇 + mbel 表达式变换（热重载）+ 客户端 SDK 雏形 | 09-15 | `e2e-p1-*.sh` |
| P2 | WASM 算子沙箱：guest SDK + ABI v1 + fuel 预算 + fail-closed；native vs wasm 字节级对拍 | 09-16 | `crosscheck-operators.sh` |
| P3 | 本地多进程集群：follower-pull 复制 + 选主 + 元数据调和，故障注入门禁 | 09-16 | `e2e-p3-*.sh` |
| P4 | 客户端 SDK 完备 + WS 网关（同端口同协议）+ 浏览器编辑器（spec 渲染器） | 09-17 | `e2e-p4-*.sh` |
| P5 | 连接多路复用（单线程 poll hub）+ 多分区数据路径 + 算子管理命令面 | 09-17 | `e2e-p5-*.sh` |
| P6 | 版本化规则资产：mbel 函数集全生命周期（发布期拦截 / re-apply 生效） | 09-17 | `e2e-p6-functions.sh` |
| P7 | 多分区复制：每分区独立水位 / 换主 / 截断；协作式节点间调用 | 09-17 | `e2e-p7-partitions.sh` |
| P8 | 存储完备：多段日志 + 稀疏索引（回退全扫逐字节一致）+ retention | 09-17 | `e2e-p8-storage.sh` |
| P9 | 消费组：协调者 + 世代围栏 + range 分配 + 托管偏移 + 地板接 retention | 09-17 | `e2e-p9-groups.sh` |
| P10 | 复制持久链接 + 预算语义：fuel 强制 / 墙钟只报告（决策 33） | 09-17 | `e2e-p7` link 腿 |
| P11 | 控制面资产下发：spec/函数集控制面持有、节点拉取、修订不回退 | 09-17 | `e2e-p11-assets.sh` |
| P12 | 安全面：四角色闭合权限表 + 握手认证 + TLS（含节点间）+ 授权门禁 | 09-17 | `e2e-p12-security.sh` |
| P13 | 控制面 poll 驱动：三服务端同一循环形状；修环状死锁与 SIGPIPE | 09-17 | `e2e-p13-control-plane.sh` |
| P14 | 键语义与键控压实：`--key` + `cluster compact`，删旧留新且偏移不变 | 09-18 | `e2e-p14`（11 腿） |
| P15 | 载荷预算：16 MiB 批上限单一真相贯穿生产/消费/复制；20 MiB 端到端 | 09-19 | `e2e-p15-bulk.sh` |
| P16 | 日志句柄复用：进程级有界缓存，12 MiB 复制由判死到秒级收敛 | 09-19 | `e2e-p16-logcache.sh` |
| P17 | 基准工具（produce/consume/latency）+ 修 accept 先于 poll 的每请求 200 ms 税 | 09-22 | `e2e-p17-bench.sh` |
| P18 | 真偏移（fetch 应答按连续段分帧）+ serve 命令面（topic 家族 + group 拒绝） | 09-23 | `e2e-p14` 腿 9–11 · `e2e-p0` 新腿 |
| P19 | 连接器流式语义（三态 pull）+ MQTT 3.1.1 连接器（零依赖手写、QoS 0 边界） | 09-23 | `e2e-p19-mqtt.sh`（5 腿，对端 = 独立 Python broker） |
| P20 | Kafka 连接器（手写五 API + RecordBatch v2 + CRC-32C；对接生态对象而非对标参考） | 09-23 | `e2e-p20-kafka.sh`（5 腿，对端校验收到的批 CRC）+ kafka-python 开发期对拍 |

### 📋 待办（按优先级）

| # | 项 | 优先级 | 说明 / 依据 |
| :--- | :--- | :--- | :--- |
| 1 | **远端仓库 + CI** | **高（工程风险）** | 全部历史（12+ 笔提交）只在单机；`gh` 未安装、无 remote。**等待外部输入**：仓库地址或装好 gh 后一条命令收口 |
| 2 | ~~Kafka 连接器~~ **已达成**（P20，09-23） | — | 五个锁定版本 API + RecordBatch v2 + CRC-32C；见决策 44。P1 尾巴的 MQTT/Kafka 两半均收口 |
| 3 | serve 的 group 协调 | 中 | 需放置 + leader 地址发现（单机无放置）；P18 已做解释性拒绝并留痕（决策 42） |
| 4 | gates.sh 补 `.mbti` 新鲜度检查 | 中（卫生） | P15 漏 `moon info` 的直接教训——「generated artifacts」步只查 Python 生成器 |
| 5 | cli-roadmap §3.3.1 过时注 | 低（卫生） | `partition list` 的理由注（「多分区存储未落地」）在 P7/P8 后已不成立；缺的只是命令本身 |
| 6 | `partition list` / `profile` / `cluster spu list` 完整字段 | 低 | cli-roadmap 仍未交付清单 |
| 7 | 批压缩（gzip/snappy） | 低（未立项） | feature-matrix ⏳ 行 |
| 8 | 细粒度 ACL / SASL / 证书轮转 / 审计日志 | 低（边界已留痕） | README 决策 35 已列为后续候选 |
| 9 | K8s 部署形态 | **最后（用户裁定）** | 弱门禁让位强门禁（roadmap §3 留痕）；真需要时先清单 + PVC 跑文件后端 |
| 10 | ABI v2 标量调用 / 多语言 SDK / 编辑器函数集 UI | 条件触发 | 触发条件未出现（决策 28 / 未立项 / 有需求再启） |

### 🚫 阻塞

| 项 | 阻塞原因 | 解法 |
| :--- | :--- | :--- |
| 远端 + CI | 缺仓库地址；`gh` CLI 未安装 | **等用户一句话**（给地址或装 gh）——其余工作不受影响 |

（除此无阻塞：待办 2–10 均可随时开工。）

### 🔁 返工台账（对已完成工作的修正与补档——诚实记录）

| # | 返工 | 触发 | 处置 |
| :--- | :--- | :--- | :--- |
| 1 | **P15/P16 延迟叙事重定价**：「20 MiB 2.0s」「12 MiB 复制 1s 收敛」大半是 accept 税，非数据搬运时间 | P17 基准首跑实测每请求恒定 ~200 ms | 修 hub（listener 进同一 poll 集）；决策 41 留痕修正旧叙事 |
| 2 | **p8 / p14 门禁时序竞态 ×2**：提速浮出（启动期 retention 扫描先于本腿 produce；follower 压实 floor 滞后一轮） | P17 提速后全量门禁两红 | 门禁侧修复（产品语义按设计正确）；各自跑 2–3 遍稳定绿 |
| 3 | **T76 范围扩大**：roadmap 写的是「规则过滤的偏移位移」，实测 **compaction 今天就触发**（幸存者 0,2,3 打成 0,1,2） | P18 实测（分段文件解码对照） | 返工为更广的连续段分帧，远端/committed/本地三路全真 |
| 4 | **布尔 flag 吞参数**：`--committed --remote X` 静默变本地消费（committed 远端读从未真正被测过） | P18 验证 T76 时 CWD 冒出杂散 `.moonflux-data` | `parse_flags` 补布尔集合 + wbtest 4 条；p14 腿 10 兼测两种顺序 |
| 5 | **log_test 重复测试**：上轮追加时复制了一份（225 实为 224） | P17 提交前核对 | 删除并重验 |
| 6 | **P15 漏 `moon info`**：公开接口与 `.mbti` 滞后一个里程碑 | P18 前盘点发现 | `9d24d34` 补档（diff 逐条核对）；暴露 gates 盲区 → 转待办 #4 |
| 7 | **roadmap 两处陈旧项**：门禁卫生已落地仍挂待办；benchmark 重复行 | P17 提交前核对 | 随 P17 提交修正 |
| 8 | **小缺陷两枚**：① `core/pipeline` 的 sink detail 对所有汇都写 "stdout sink"（对 http/mqtt 汇是说谎）；② `spec_wbtest` 用 `"mqtt"` 当「未知类型」的例子，P19 让它变成已知——测试例子随之失效 | P19 实现时发现 | 当场修（sink detail 按 spec 取；测试改用 `amqp`）。**该地雷在 P20 三度踩响**：spec 单测与金标语料里的「未知类型」示例恰好又用了 `"kafka"`——两处改 `kinesis` 并重生成语料。教训已写进 `main_wbtest`/语料的改动本身：**新增已知类型时，先 grep 全部把该名字当「未知例子」的夹具**。 |

---

## 功能点简介（平台现在能做什么）

**数据面**：分区提交日志（追加 / 窗口读 / 任意偏移重放）；多分区（每分区独立日志）；段化存储（滚动、稀疏索引、retention 只删整段）；**键控压实**（删旧留新、偏移不变、空洞两侧可读）；**载荷预算**（16 MiB 批上限单一真相派生全链路，20 MiB 文件端到端逐字节一致）；**真偏移**（压实/过滤后的空洞两侧，消费显示幸存记录的真实偏移）。

**集群**：follower-pull 复制（逐分区水位 / 换主 / 分歧截断并报告丢弃量）；SC 控制面（声明式主题与放置调和、poll 驱动、单机 `serve` 与多进程 `sc + spu` 同一二进制）；消费组（协调者唯一权威、世代围栏、range 分配、托管偏移、消费地板挡 retention）；控制面资产下发（spec/函数集控制面持有、节点拉取、修订不回退）。

**安全面**：四角色闭合权限表（未列命令默认拒绝）、握手期认证（认证前不服务任何命令）、TLS 单向/双向（客户端强制校验、节点间加密）、凭据只做参数不入日志。

**可编程**：mbel 表达式变换（消费路径执行、热重载、历史按当前规则重现）；版本化函数集（发布期静态检查 + 编译两道闸）；WASM 算子沙箱（ABI v1、fuel 确定性预算、失败 fail-closed）；PipelineSpec 单一真相（编辑器只是渲染器）。

**客户端与工具**：单二进制多子命令 CLI（produce / consume / serve / spu / sc / topic / group / cluster / operator / benchmark / pipeline / function-set）；WebSocket 网关（同端口同协议）；浏览器编辑器（拖拽 → 部署 → 消费）；**基准工具**（produce 吞吐 + 逐批延迟、consume 抽干与序号完整性校验、latency 端到端可见性——本地铁环回 ack ~4 ms / e2e p50 ~189 µs）；**MQTT 连接器**（P19）与 **Kafka 连接器**（P20：消费源 + 生产汇，手写锁定版本协议与 RecordBatch v2，CRC-32C 外部锚点验证）。

**工程面**：一内核多后端（core 在 wasm / wasm-gc / js / native 四后端编译矩阵下保持可编译）；37 步门禁（故障注入、对拍、结构断言）；golden vectors + 独立 Python 协议第二实现；44 条关键决策记录全程留痕。

---

## 维护规则

- 每轮里程碑收口时随提交更新本看板（已完成 / 待办 / 阻塞 / 返工四条道都要动）；快照日期同步。
- 本文只做**汇总与指引**：细节回链 roadmap / feature-matrix / compatibility-matrix / 决策记录 / ticket；不在此复制它们的全文（单一真相纪律，AGENTS §10）。
- 返工台账**只增不删**：返工是过程资产，删掉它等于假装没发生过。
