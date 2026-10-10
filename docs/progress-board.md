# moonflux 进度看板（快照）

> **定位**：**带日期的进度快照与看板**——已完成 / 待办 / 优先级 / 阻塞 / 返工一页可读，并附功能点简介。**规约依据**：AGENTS.md §10（文档规范）；**边界声明**：本文是**派生视图**，不是单一真相——阶段详情与排期的真相在 [`project-roadmap.md`](project-roadmap.md)，能力清单在 [`feature-matrix.md`](feature-matrix.md)，对标语义在 [`compatibility-matrix.md`](compatibility-matrix.md)，决策依据在 README「关键决策记录」（现 1–53），工作项在 `.scratch/moonflux-p{N}/issues/`（编号 01–102 全局连续）。快照日期见下；每轮里程碑收口时随提交更新。

**快照日期**：2026-10-10 · 状态：**P0–P29 全部达成** · 门禁全套 **46 步绿**（native 289 / wasm-gc 186 / 算子 7）· **CI 已接线且两腿均绿**：`fast`（12 步）随推送在 **Linux**（run `36324100660`，1 分 41 秒——本仓**首次 Linux 验证**）；`full`（43 步 E2E）手动在 macOS **首次跑满 43/43**（run `36325414560`，5 分 13 秒）

---

## 看板

### ✅ 已完成（P0–P26 全部收口，27 行，证据可复现）

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
| P21 | 细粒度授权（per-topic grants，只收窄不放宽）+ 安全审计日志（认证/拒绝/主题生命周期 JSON 行） | 09-25 | `e2e-p12-security.sh`（10 腿；腿 8–10 为新增） |
| P22 | 单机消费组：serve 自任协调者（同一注册表/命令/围栏）+ 分区枚举 = 声明∪磁盘 + 地板接最慢消费者 | 09-25 | `e2e-p22-serve-groups.sh`（7 腿）+ `e2e-p0` 翻转的 group 腿 |
| P23 | 命令面尾巴：`partition list` / `cluster spu list` / `profile` 档案；serve 补 OFFSET_INFO | 09-25 | `e2e-p23-cli.sh`（5 腿）+ profile wbtest 4 条 |
| P24 | 无重启轮转：TLS/凭据表 mtime 监视热重载 + 明文警告 + SASL 边界声明 | 09-25 | `e2e-p24-rotation.sh`（4 腿）+ rotation wbtest 3 条 |
| P25 | 批压缩：DEFLATE 进 core/codec（Python zlib 锚定 + 炸弹上界）+ Kafka gzip 双向 | 09-25 | `e2e-p25-compression.sh`（4 腿）+ codec wbtest 9 条 |
| P26 | ABI v2 标量调用：沙箱标量函数 + 与 mbel 逐字节对拍 + 探针无导入段检查 | 09-25 | `e2e-p26-scalar.sh`（6 腿）+ wasmtime wbtest 9 条 |
| P27 | 编辑器函数集 UI：面板/表单/选择器/漂移标记，资产与协议帧全在内核（ABI 2）；UI 不暴露标量函数面 | 10-05 | `e2e-p27-editor-functions.sh`（3 腿）+ wbtest 11 条 |
| P28 | 存储维护调度：后台压实加入既有维护节拍（节拍即开关、门槛透传内核、floor 单一真相、spu 与 50ms tick 解耦） | 10-06 | `e2e-p28-maintenance.sh`（5 腿，进步表）+ wbtest 3 条 |
| P29 | SDF 示例集的 8 个应用案例（examples/sdf/*）+ 两个沙箱算子（filter 1→0 / flatmap 1→N）+ Studio 对标探索与三阶段提案 | 10-10 | `scripts/e2e-p29-examples.sh`（8 腿）· `docs/sdf-examples-port.md` · `docs/sdf-studio-exploration.md` |

### 📋 待办（按优先级）

| # | 项 | 优先级 | 说明 / 依据 |
| :--- | :--- | :--- | :--- |
| 1 | **远端仓库** | **已达成** | 94 笔提交全历史推送到 `github.com/dimon-83/moonflux`（本地 `main` 与 `origin/main` 同步） |
| 1b | ~~**CI 接线**~~ | **已达成（2026-09-27）** | [`.github/workflows/ci.yml`](../.github/workflows/ci.yml) 落地：带 `workflow` scope 的凭据就位后推送成功，`fast` 首绿（run `36324100660`，1 分 41 秒）。见决策 51 与返工台账第 11 条；`full`（macOS 全套 E2E）首次手动运行的结果单列 |
| 2 | ~~Kafka 连接器~~ **已达成**（P20，09-23） | — | 五个锁定版本 API + RecordBatch v2 + CRC-32C；见决策 44。P1 尾巴的 MQTT/Kafka 两半均收口 |
| 3 | ~~serve 的 group 协调~~ **已达成**（P22，09-25）· ~~命令面尾巴（partition list / profile / spu list）~~ **已达成**（P23，09-25） | — | serve 自任协调者：同一注册表/命令/围栏（决策 46）；三条挂账命令清账（决策 47）。P18 的解释性拒绝退役（`e2e-p0` group 腿翻转为协调断言） |
| 4 | ~~gates.sh 补 `.mbti` 新鲜度检查~~ **已达成**（2026-09-24） | — | stale `.mbti`（含已 staged 未提交的）会红全量门禁 |
| 5 | ~~cli-roadmap §3.3.1 过时注~~ **已达成**（P23，09-25） | — | §3.3.4 回填：三条命令清账、`--help` 非错误退出留痕、`topic add-partition` 明确不做（放置调和事件） |
| 7 | ~~批压缩~~ **已达成**（P25，09-25） | — | DEFLATE 进 core/codec + Kafka gzip 双向；自有 MFS 帧仍为未压缩（显式边界，决策 49） |
| 8 | ~~细粒度 ACL / 审计日志~~ **已达成**（P21）· ~~证书轮转~~ **已达成**（P24）· SASL **边界声明**（决策 48：token-over-TLS 已覆盖；Kafka 连接器侧 SASL/TLS 为互操作候选）；剩余压缩 | 低 | 见决策 45/48 |
| 9 | K8s 部署形态 | **最后（用户裁定）** | 弱门禁让位强门禁（roadmap §3 留痕）；真需要时先清单 + PVC 跑文件后端 |
| 10 | ~~ABI v2 标量调用~~ **已达成**（P26，09-25）· ~~编辑器函数集 UI~~ **已达成**（P27，10-05）；剩余：多语言 SDK | 条件触发 | 见决策 50/52 |
| 11 | **编辑器拓扑视图（Studio 提案 P1）** | 条件触发 | 把 `core/pipeline` 的编译结果渲染成只读节点/边；P2 活指标、P3 诚实版状态视图同文档 §4——**三阶段均未立项** |
| 12 | **SDF 缺口追平分批**（见 `docs/sdf-gap-closure-plan.md`） | 进行中 | 连接器案例（09–11，6 腿）与 **T108 静态检查探针**（决策 55）已落地——后者解锁 JSON 字段读写（案例 12 三腿含**恒等往返**）与 `parse-sentence`（案例 13），`e2e-p29-examples.sh` 8 → 12 腿；**函数集本地创建（T107，决策 56）**也已落地（P6 门禁第 11 条，案例 01 不再需要 serve）；余下：轮询 HTTP 源、算子作者指南 + C ABI 头、正则基础能力；状态与窗口（P32）须先出 ABI v3 设计稿 |

### 🚫 阻塞

| 项 | 阻塞原因 | 解法 |
| :--- | :--- | :--- |
| — | **无阻塞** | 剩余待办（K8s 部署形态 / 多语言 SDK）都是条件触发或用户已裁定排最后 |

（远端 + CI 接线已于 2026-09-27 清账：仓库与工作流都在线上，`fast` 首绿。）

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
| 9 | **e2e-p12 腿 7 假阳性**：门禁自己的 awk 把 `hw=?`（leader 不可达哨兵）当 settled——awk 对 `"?"` 与 `"2"` 做字符串比较且 `"?"` 更大；负载波峰下 p0 同步链接慢一个节拍 → 状态查询超时进 `hw=?` → SETTLED 假通过 → 立刻字节比对空 follower → FAIL。追了三轮（先疑审计 fsync、再疑 P21 数据路径改动），全部排除 | P21 提交前循环压测 | awk 只认 `hw=[0-9]+`（哨兵在解析处显式拒绝）；修复后 10/10 稳定。教训入 AGENTS P17 纪律块：**门禁自己的解析器也是不可信输入的解析器**。p3/p7 的单分区精确断言（`[ "$HW" = "3" ]`）天然免疫 |
| 10 | **盘点浮出两类旧账**：① `gates.sh` 四条编译矩阵腿对**非 "Error" 的失败**报 PASS（实测：把 `moon` 移出 PATH，四条腿全绿——CI runner 装不上工具链时会假装通过）；② 文档漂移——board 头部称「CI 已接线」而自身待办/阻塞仍挂在待办、P21 收口日期写成 09-24（实为 09-25）、README 缺决策 50 且决策 43 错序、architecture/feature-matrix/user-guide/production-readiness 仍写 37 步、roadmap 头部停在「P0–P20 · 37 步」、user-guide 脚本索引缺 P22–P26 五行 | 用户问「当前进度」时的全量盘点（不是门禁抓到的） | 本轮一并修：矩阵腿改看退出码并打印输出（缺工具链 / 编译错 / 成功三路各自实跑验证）；文档计数与 CI 叙事全量对齐；README 补决策 50、43 归位；production-readiness 按维护规则回填 P21–P26 已交付项并改写分级结论 |
| 11 | **CI 首跑抓出的五件事**（没有一件是读文档能发现的）：① 新机器没有 registry 索引 → `dimon-83/mbel` 解析失败，**十条腿全红**（源码明明已 vendored 在 `.mooncakes/`）；② wasmtime 的头/库路径硬编码 Homebrew → Linux 上 **native 后端根本编不出来**；③ `fs_shim.c` 的 `st_mtimespec` 是 macOS 独有（glibc 为 `st_mtim`）；④ 编译矩阵对"非 `^Error` 的失败"报 PASS（`moon` 移出 PATH 后四条腿全绿）；⑤ `moon info` 吞掉 stderr、只看 `git status` → 依赖图坏掉时照样报"接口新鲜" | 用户提供带 `workflow` scope 的凭据、CI 真跑起来。**注意 ④⑤ 是门禁自己的假绿**——抓它们的是 CI，而 CI 用的正是这两条腿 | ① `moon update` + 索引缓存；② `-I/usr/local/include` + 平台化 dlopen 兜底 + CI 装官方 48.0.2 C API（与本地同版本，决策 14/T15 的镜像尺寸前提）；③ `__APPLE__` 分支；④⑤ 看退出码并打印输出（各自三路/日志实测）。**工具链漂移**（CI 装 latest vs 本地 `0.1.20260629`，而 CDN 拒版本化 URL）在决策 51 给出政策：仓库采纳 CI 那一版，`moon fmt` + `moon info` 重排 59+7+27 个文件（`.mbti` 非空行零变化），本地须 `moon upgrade` |
| 12 | **决策 50 被插进了决策 49 的段落中间**（我上一轮补决策 50 时，用"行首编号"匹配插入点，而 49 是**多行**段落，于是 50 那行落进了 49 的第一行之后，把 49 截成两半——编号顺序看起来是对的，因为顺序检查也只看了行首） | 写决策 51 时读回文件，发现 49 的段落少了尾巴 | 把 50 移到 49 段落**之后**（按"49 的结尾行"定位，不按行首编号），再追加 51；顺带记教训：**多行段落不要用行首前缀做插入锚点** |
| 13 | **门禁的启动时序假设**（full 首跑 43 步里 2 红：p12/p13）：两个门禁从**端口**学"服务起来了"，然后立刻 `grep` 一次日志；而 `sc` 是先打印 `listening`、**再**加载凭据表与 OpenSSL 上下文/证书（`apps/cli/node.mbt` 的 `sc` 启动序列）。runner 冷缓存下这个窗口比一次 grep 长——失败输出里的日志只有 `listening` 一行，**距该行出现仅 0.34 ms**（日志时间戳） | 首次手动 full 跑。**注意这是门禁的假设错，不是产品缺陷** | 新增有界等待 `wait_log`（默认 10 s，TLS 处 15 s；超时仍失败并打印日志，断言不减弱），并改掉同类站点（p12 腿 1、p12 腿 2、p13 三处、p24 明文警告）；`p5` 那条不动——它在服务跑完整场之后才查，不存在该竞态。三路单测 + 三条门禁本地回归（p12 10 腿 / p13 5 腿 / p24 4 腿）。**产品无缺陷的证据同在一次跑里**：`e2e-p24-rotation` 做完整 mTLS 轮转（换 CA、旧 CA 被拒、凭据轮换）4 腿全绿——说明 TLS 在 runner 上可用、控制面确实起来了。顺带修掉一个隐藏前置：`scripts/mfs_probe.py` 的 `str | None` 注解没有 `from __future__ import annotations`，等于**隐式要求 Python ≥3.10**（macOS 自带 3.9 直接 TypeError） |
| 14 | **`mf_editor_feed` 的 apply 应答试探误读长 JSON 应答**：LIST/CREATE 应答的首字节 `[`（91）/`{`（123）在载荷够长时通过 uleb 试探的长度上界（≤128），被解码成 `deployed pipeline "{\"name":…`——面板首刷时每行日志都成了假部署。**wbtest 的短夹具当年全绿**（49 字节的数组过不了 91 字节的读取），真页面第一条 LIST（>91 字节）才现形 | P27 真浏览器驱动阶段（合成事件绕过指针交付问题后，日志第一眼就露出假 `deployed` 行） | 修法为**解码次序**：JSON 函数集应答（数组/带 `created` 的对象）**先于** uleb 试探——二进制载荷解析 JSON 必败、自然落空；新增**长夹具**回归（>91 字节的 LIST 应答断言无 `pipeline` 键）。教训入 AGENTS P4 块：**夹具必须覆盖真实载荷的长度级别**；另留痕一个驱动环境事实：IAB 面板的指针事件（Playwright click 与 CUA 坐标）在后台不交付，页面钩子（`window.moonfluxEditor`）与合成事件是为此设计的驱动面 |

---

## 功能点简介（平台现在能做什么）

**数据面**：分区提交日志（追加 / 窗口读 / 任意偏移重放）；多分区（每分区独立日志）；段化存储（滚动、稀疏索引、retention 只删整段）；**键控压实**（删旧留新、偏移不变、空洞两侧可读）；**载荷预算**（16 MiB 批上限单一真相派生全链路，20 MiB 文件端到端逐字节一致）；**真偏移**（压实/过滤后的空洞两侧，消费显示幸存记录的真实偏移）。

**集群**：follower-pull 复制（逐分区水位 / 换主 / 分歧截断并报告丢弃量）；SC 控制面（声明式主题与放置调和、poll 驱动、单机 `serve` 与多进程 `sc + spu` 同一二进制）；消费组（协调者唯一权威、世代围栏、range 分配、托管偏移、消费地板挡 retention；**P22 起单机 serve 同一语义自任协调者**）；控制面资产下发（spec/函数集控制面持有、节点拉取、修订不回退）。

**安全面**：四角色闭合权限表（未列命令默认拒绝）、握手期认证（认证前不服务任何命令）、TLS 单向/双向（客户端强制校验、节点间加密）、凭据只做参数不入日志；**per-topic grants**（P21：授权只收窄不放宽，角色表先行；Node/Root 不受 grant 约束）与**安全审计日志**（`<data-dir>/audit.log` JSON 行：认证结果 / 权限拒绝 / 主题生命周期，凭据永不入账）。

**可编程**：mbel 表达式变换（消费路径执行、热重载、历史按当前规则重现）；版本化函数集（发布期静态检查 + 编译两道闸）；WASM 算子沙箱（ABI v1、fuel 确定性预算、失败 fail-closed）；PipelineSpec 单一真相（编辑器只是渲染器）。

**客户端与工具**：单二进制多子命令 CLI（produce / consume / serve / spu / sc / topic / group / cluster / operator / benchmark / pipeline / function-set）；WebSocket 网关（同端口同协议）；浏览器编辑器（拖拽 → 部署 → 消费；**P27 起带函数集面板/表单/选择器/漂移标记**——资产文档与协议帧全在 `apps/editor-kernel`）；**基准工具**（produce 吞吐 + 逐批延迟、consume 抽干与序号完整性校验、latency 端到端可见性——本地铁环回 ack ~4 ms / e2e p50 ~189 µs）；**MQTT 连接器**（P19）与 **Kafka 连接器**（P20：消费源 + 生产汇，手写锁定版本协议与 RecordBatch v2，CRC-32C 外部锚点验证）。

**工程面**：一内核多后端（core 在 wasm / wasm-gc / js / native 四后端编译矩阵下保持可编译）；46 步门禁（故障注入、对拍、结构断言）；**CI 已接线**（`fast` 随推送在 Linux、`full` 手动在 macOS）；golden vectors + 独立 Python 协议第二实现；54 条关键决策记录全程留痕。

---

## 维护规则

- 每轮里程碑收口时随提交更新本看板（已完成 / 待办 / 阻塞 / 返工四条道都要动）；快照日期同步。
- 本文只做**汇总与指引**：细节回链 roadmap / feature-matrix / compatibility-matrix / 决策记录 / ticket；不在此复制它们的全文（单一真相纪律，AGENTS §10）。
- 返工台账**只增不删**：返工是过程资产，删掉它等于假装没发生过。
