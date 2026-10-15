# moonflux 进度看板（快照）

> **定位**：**带日期的进度快照与看板**——已完成 / 待办 / 优先级 / 阻塞 / 返工一页可读，并附功能点简介。**规约依据**：AGENTS.md §10（文档规范）；**边界声明**：本文是**派生视图**，不是单一真相——阶段详情与排期的真相在 [`project-roadmap.md`](project-roadmap.md)，能力清单在 [`feature-matrix.md`](feature-matrix.md)，对标语义在 [`compatibility-matrix.md`](compatibility-matrix.md)，决策依据在 README「关键决策记录」（现 1–53），工作项在 `.scratch/moonflux-p{N}/issues/`（编号 01–102 全局连续）。快照日期见下；每轮里程碑收口时随提交更新。

**快照日期**：2026-10-10 · 状态：**P0–P29 全部达成** · 门禁全套 **54 步绿**（native 314 / wasm-gc 210 / 算子 7）· **CI 已接线且两腿均绿**：`fast`（12 步）随推送在 **Linux**（run `36324100660`，1 分 41 秒——本仓**首次 Linux 验证**）；`full`（43 步 E2E）手动在 macOS **首次跑满 43/43**（run `36325414560`，5 分 13 秒）

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
| 0a | **P37-1 多任务地基（本地口径）** | ✅ 2026-10-13 | 决策 81：`topology.json` v2 集合 + 按名 upsert/`--set`/`delete`/`list` + **取数按 topic 选链** + v1 内存迁移 + `moonflux_tasks` 无标签 gauge；门禁 `e2e-p37-multi-task.sh` **10 腿**。顺带修：健康检查恒真、诊断走块缓冲 stdout、`--set` 吞参数（并加 `audit-flags.py` 门禁防这一类） |
| 1p | **汇进集群（P1-2b-i）** | ✅ 2026-10-16 | 决策 121：集群数据模式 + topic 汇（复用 append_to_cluster）；源按名拒绝；p58 4/4；修重试循环不响应停止信号 |
| 1m | **CI exit 143 嫌疑：p48 清理** | ✅ 2026-10-15 | 决策 119：p48 的 pid 清单清理换成作用域化操作（回收 pid 可杀到 runner agent）；两周 CI 同点同因两平台 ✓；**间接证据**，修复后仍需 CI 复验 |
| 1k | **运行日志进集群（P1-2a）** | ✅ 2026-10-15 | 决策 118：runner 传 `--state-remote`、`task logs --remote` 解析 leader 再读、无宿主明说；p57 5/5（含"杀 runner 后仍可读"边界腿）| 
| 1j | **P1-2 设计稿 + 门禁安全修复** | ✅ 2026-10-15 | 决策 116/117：`pkill -f ""` 守卫（审计抓出 7 个）；[task-cluster-data-plane.md](task-cluster-data-plane.md) 设计稿（P1-2a/2b 判据与风险）| 
| 1h | **多点位（P1-1）** | ✅ 2026-10-15 | 决策 115：`expand_points` + `apply --points`；树内替换、复用 `{标识符}` 约定、撞名/笔误拒绝；21/21 + p56 4/4 |
| 1g | **崩溃循环要可见（P0-3）** | ✅ 2026-10-15 | 决策 113：`state=crash-loop`（频率+含义，盖过 running、disabled 优先）；判据只用心跳可见的事实；68/68 + p55 4/4 |
| 1f | **部署并轨管理平面（P0-2）** | ✅ 2026-10-15 | 决策 112：sc + 一个 runner（两平台单元/生成器/发布脚本/回滚）+ `replay_warnings` + p54 6/6；实机抓到工程外崩溃循环（PGRST302 匿名访问关闭）| 
| 1e | **管理界面收口（P37-5c）** | ✅ 2026-10-15 | 决策 111：调度面板 + 生命周期按钮 + p53 4/4；修 js 导出清单/ABI 5/`has_document`；内核 14/14 |
| 1d | **开发计划 + 管理界面第一片** | ✅ 2026-10-15 | 决策 110：[dev-plan.md](dev-plan.md) 收益排序；内核 schedule/task_enabled 两帧 + js 测试进门禁（13/13）；页面留下一片 |
| 1c | **安全跑法机制化** | ✅ 2026-10-15 | 决策 109：`run-watched.sh` + CI 监控+artifact + 前台提示 + `--suite` 自检 |
| 1b | **铁律落地：never + 运行表** | ✅ 2026-10-15 | 决策 108：`Child.done`（CI 抓出 never 被复活）+ 门禁竞态修 + `RunTable` 有界（活运行不淘汰）| 
| 1a | **铁律：资源 + 文档语言** | ✅ 2026-10-15 | 决策 107：英文 `AGENT.md`（两条铁律）+ `AGENTS.md` 指针；双语副本后补 |
| 0z | **task logs 两类证据** | ✅ 2026-10-15 | 决策 106：`mf_cli_spawn_to`（无 shell 的 stderr 重定向）+ 每任务 stderr 文件 + `task logs` 一并输出；p51 5/5 |
| 0y | **空闲不是死亡（idle 心跳）** | ✅ 2026-10-15 | 决策 105：docker 门禁抓出"空闲任务被误判 offline"；`RunSession::idle` + 两循环；p49 7a/7b + p51 1b |
| 0x | **docker 集群测试补全（目标 ④）** | ✅ 2026-10-15 | 决策 104：p49 动态 9 条腿（调度/有输出/回收窗口/offline/重分配） |
| 0w | **带监控跑（真因定案）** | ✅ 2026-10-15 | 决策 103：整套 **75 passed/0 failed**（脱离式+监控）；工作负载 5 进程/116MB、客户端 +151MB、swap 0 ⇒ 崩溃=前台管道继承 |
| 0v | **门禁卫生审计（静态）** | ✅ 2026-10-15 | 决策 102：静态审计器 + 59 门禁全清 + 修 3 处清理 + runner 泄漏；排除版本/OOM |
| 0u | **门禁进程/管道安全** | ✅ 2026-10-15 | 决策 101：`gates-bg.sh` 全脱离（0.46s 返回）+ 每步进程组看门狗；超时压 1s 验证：4 步被收、泄漏 0 |
| 0t | **控制面对账 + 远程启停** | ✅ 2026-10-14 | 决策 100（P37-5b 收口）：对账表 + 心跳下放置 + start/stop --remote；门禁 4 条 |
| 0s | **输出预算（资源）** | ✅ 2026-10-14 | 决策 99：门禁默认摘要、全文落盘；**实测 fast 15451 行 → 126 行**；`quiet-run.sh` |
| 0r | **task start/stop + runner 对账** | ✅ 2026-10-13 | 决策 98：enabled 进文档、task stop/start、runner 500ms 对账；门禁 3 条。**未做**：控制面侧对账循环 |
| 0q | **调度：target + worker 过滤** | ✅ 2026-10-13 | 决策 97：每任务 target 进文档、runner --worker 只跑自己的任务；门禁 3 条。**未做**：控制面对账循环、task start/stop |
| 0p | **task 只读命令面 + restart 进文档** | ✅ 2026-10-13 | 决策 96：task status/logs；restart 进任务集文档、runner 按任务读。**未做**：task start/stop + target 调度 |
| 0o | **runner 监督器** | ✅ 2026-10-13 | 决策 95：起/停/重启子进程 + 优雅 SIGTERM；门禁 4 条。**未做**：调度 + docker 集群测试 |
| 0n | **外部失败重试** | ✅ 2026-10-13 | 决策 94：源/汇失败退避重试、进程不死、汇批次不丢；门禁 4 条。**未做**：一个进程跑整个任务集（N 点位 = N 进程） |
| 0m | **部署产品化** | ✅ 2026-10-13 | 决策 93：两段管道（判决落主题、键＝点位；STUCK 外发 webhook）＋ systemd/launchd ＋ logrotate ＋ **重启即重放**；http 汇补齐 headers/ca；门禁 **4 条**。部署指南在工程外 `moonflux/README.md` |
| 0l | **TLS 发 SNI** | ✅ 2026-10-13 | 决策 92：**真实端点直连成功**（根因＝shim 从不发 SNI ✗；`SSL_set_tlsext_host_name` 是宏、dlsym 拿 NULL 使第一版修复静默失效 ✗）；p45 增双向 SNI 腿；部署 spec 切直连、桥退休 |
| 0k | **http 源 https/TLS** | ✅（本地夹具）· ⏳（真实端点） | 决策 91：scheme 分派 + `source.ca` + 缺 ca 校验期拒 + 无隐式信任库；门禁 **5 条**（含错锚与名字不匹配的拒绝路径）。**未解决**：真实端点 `verify failed (code 20)` ✗ 而 openssl 同 bundle 通过 ✓（服务器链完整 ✓） |
| 0j | **http 源请求头** | ✅ 2026-10-13 | 决策 90：`spec.source.headers` + 注入守卫（CR/LF/NUL 拒）+ 排序确定；门禁 **5 条**断言**对端**收到的头（缺头 404 的夹具服务）。**https 待做** |
| 0i | **时间戳解析放宽** | ✅ 2026-10-13 | 决策 89：微秒校验后截断、接受固定偏移（真实 feed 的 `+08:00`）；理由与 wbtest 见决策。**待办**：GuestTrap 错误文本里的中文不可读 ✗（数据链路正确） |
| 0h | **点位恒值检测算子** | ✅ 2026-10-13 | 决策 88：`apps/operator-stuck`（有状态、事件时间、可疑值即刻告警、断流记录不切段、水位去重）；真实数据（4 天 5732 条）对拍参考实现；门禁 **7 条**抓出两个真 bug。**待做**：http 源加请求头与 TLS 才能直连该点位 |
| 0f | **SDF 例子 native 部署** | ✅ 2026-10-13 | 决策 86：`deploy-sdf.sh` + 部署根 + 三种模式（无静默跳过）；**每用例自己的数据目录**化解跨用例主题冲突（sentence/cars）；门禁 **7 腿**。指南 [`deployment.md`](deployment.md) |
| 0g | **SDF 例子 Docker 部署** | ✅ 2026-10-13 | 决策 87：多阶段 Dockerfile + compose（broker/console/一用例一容器/集群 profile）；**本机无守护进程**，动态证明在 CI `docker` 作业（`MOONFLUX_REQUIRE_DOCKER=1`，含容器内真实用例逐字节对拍）；套件内只做静态且明说；**实测 8/8（3 静态 + 5 动态）**：镜像 70.5 MB、`doctor`/视图模型/broker `/healthz`/用例容器内逐字节对拍；顺带修出仓库真 bug——**算子模块此前无法从干净树构建** |
| 0e | **P37-3b 控制台面板** | ✅ 2026-10-13 | 决策 85：任务清单 + 运行面板；ABI 4；**按 request id 读应答**；门禁让 node 用页面产物**连真 broker** 与 CLI 逐字段对拍（抓到"内核少读一层文档"的真 bug）。门禁 **5 腿** |
| 0d | **P37-3a 控制台视图模型** | ✅ 2026-10-13 | 决策 84：内核导出 `view_model` + CLI `pipeline view` + 页面拓扑面板；**CLI 与页面 JS 产物逐字节一致**（门禁在 node 里跑真产物）；ABI 3。门禁 **5 腿**。**3b（任务清单/执行记录面板）待做** |
| 0c | **P37-2 运行登记** | ✅ 2026-10-13 | 决策 83：`run list` + `CMD_RUN_REPORT`（Node）/`CMD_RUN_LIST`（只读）；**stopped vs offline 可区分**且回收不碰 stopped；run-log 主题 + **run id 由偏移推导**；无标签 metrics。门禁 **7 腿**。顺带修：负数 uleb 往返（-1 读成 127）、CLI 动词白名单（新增 `audit-verbs.py`） |
| 0b | **P37-1b 集群多任务** | ✅ 2026-10-13 | 决策 82：控制面持集合文档 + 一个文档级修订；`apply --remote` 三形状（信封）+ `delete --remote`；节点**整份采纳**；被拒发布不动修订；坏文档拒收保留。门禁 `e2e-p37b-cluster-tasks.sh` **6 腿** |
| 0 | **P37 任务控制台**（2026-10-11 立项） | **高** | 决策 79 + 设计稿 [`task-console.md`](task-console.md) + ticket [`.scratch/moonflux-p37/issues/00-overview.md`](../.scratch/moonflux-p37/issues/00-overview.md)。用户裁定：**多任务改平台侧**（`topology.json` → 多管道集合 + 一个文档级修订、取数按 topic 选链）、**执行记录以 run-log 主题为准**、**首期 = 运行登记 + 只读拓扑/任务清单**。已证实的动因：`pipeline run` 对平台完全不可见（进程里 REGISTER/HEARTBEAT 出现 0 次） |
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
| 12 | **SDF 缺口追平分批**（见 `docs/sdf-gap-closure-plan.md`） | 进行中 | 连接器案例（09–11，7 腿）、T108 探针（决策 55，解锁 JSON 字段读写与含**恒等往返**的案例 12）、T107 函数集本地路径（决策 56）、T109 轮询 HTTP 源（决策 57）、T112 作者指南 + C ABI 头（决策 58）、T111 正则能力（决策 59，`core/regex` + 案例 14）均已落地，p29 门禁 8 → 17 腿；**T113 状态/窗口设计稿已出**；**T114 第 1–3 步已完成**：v3 信封/SDK/探针/C 头 + 适配器链路 + `operator-counter`/`operator-wordkeys` + `spec.state` + 宿主视图与写回，**门禁 `e2e-p31-state.sh` 11 腿**（含**窗口即键的形状**与"复制状态主题复现视图"），**宿主侧 callout（决策 66）落地**（`mode` 必填、磁带、凭据不入、期限；`e2e-p32-callout.sh` 9 腿，总步数 48）| 14 | **P34：用户裁定的五项工程**（`ticket .scratch/moonflux-p34/`） | 进行中 | ✅ ① 控制面 HA + 备份/恢复（决策 74，`e2e-p34-sc-ha.sh` 12 腿）；✅ ② Linux 全量门禁 + macOS `F_FULLFSYNC` 真落盘（决策 75，`full-linux` job + `doctor` + p8 平台断言）；✅ ③ metrics + 健康端点（决策 76，`e2e-p35-metrics.sh` 10 腿；抓出租约临时文件碰撞与非 HTTP 挂住两个 bug）；✅ ④ 有状态管道的跨节点迁移与续算（决策 77：状态随复制走 + 进度标记 + `--state-remote` 单写入者；`e2e-p36-state-migration.sh` 8 腿，抓到"两进程共写一个数据目录导致状态永不复制"的真缺口）；⏳ **键空间再均衡**未立项；✅ ⑤ 镜像/多区域与恰好一次/事务**各写了显式决策**（决策 78：不做、为什么、触发条件、替代） |
| 13 | **P31：把如实留档的两处补成真能力**（ticket `115-two-gaps.md`，见决策 69） | 进行中 | ✅ 窗口关闭的 flush（`operator-topwords` + `operator-keyconst`，数据驱动水位；案例 15 重写为参考的真实形状，并**纠正了我此前写错的一条 dedupe 差异**；ISO 解析移入 SDK）；✅ 状态**字段级合并**（决策 70：`loadtable.merge`，批内进行中的行自己记）；✅ **dedupe**（决策 71：`operator-dedupe`，去重期限 = 键的形状；扩展案例 26）；✅ **主题源 + 主题汇**（决策 72，缺口 7 追平：跟随者旁路缓存、四条环校验、11 腿门禁）；✅ 案例 16/17/23/25 的**接力升级**（决策 73：跟随者 + 有界等待门禁，结果逐字节不变）——P31 收口 |
+ **全部 26 个参考条目已判定**（覆盖清单 + 核对门禁，自带反向验证）；示例 `22-http-callout`/`23-update-state`/`24-openai-callout`/`25-hackernews-notify` 入册（p29 42 腿 + p30 3 腿 = 25 个应用）；**七个状态示例已入册**（`15-word-counter`、`16-word-probe`、`17-bank-processing`、`18-unreal-engine-analytics`、`19-car-processing`、`20-helsinki-transit`、`21-ny-transit`；p29 15 → 33 腿、14 → 21 个应用）；缺口 10（结构化谓词）收口；决策 63/64/65（批上限、定向字段读取器、ISO-8601 与参考表、窗口均值与时区纪律）；顺带修掉陈旧制品假绿（返工台账第 14 条） |

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
| 15 | **依赖变更不会被新鲜度检查发现**（T114 加 SDK 的 JSON 定向读取器时实测）：第 14 条给每个算子加了"制品必须新于**它自己包内**源码"的检查，但**算子依赖的 SDK/core 变更不在检查范围内**——`json_field.mbt` 新增后，算子的 `.wasm` 逻辑上已陈旧而检查照样 green（两者的 mtime 落在同一秒，连偶然发现都不可能）。**修法方向**：新鲜度比较必须包含**依赖闭包**（保守做法：`core/**` 与 `apps/**` 的任何源码比制品新就重建该包——不追踪依赖图，宁可多重建）。这条与第 14 条同源（"工具跑了"≠"跑对了"），是它的第四种形态（**依赖新鲜度**）。 |
| 14 | **算子构建的陈旧制品假绿**（T114 加 `operator-counter` 时实测）：`scripts/build-operators.sh` 的第一步是模块级 `moon build --target wasm --output-wat`，而实测它**会跳过源码已改的包**——于是 for 循环量到的是旧 `.wasm`、探针校验的也是旧字节、测试跑的是上一次的行为。观察到的形态极具误导性：包级 `moon build --target wasm apps/operator-counter` 能编出 232385 字节的新制品，而模块级构建后目录里仍躺着 222667 字节的旧制品，脚本照报 "operator-counter: 222667 bytes" 并继续到 "all green"。**修法（已落地）**：每个算子加一条**制品必须新于其源码**的检查（`find apps/$op -newer "$WASM" -name '*.mbt' -o -name moon.pkg`，BSD/GNU 通用）；不新则**显式重建该包并复检**，复检仍旧即红。反向验证：`touch -t 202001010000` 伪造旧制品 → 门禁红并指出"未经本次源码构建"。**教训**：工具"跑了"不等于"跑对了"——沿用决策 51 那条（退出码/新鲜度要显式校验），这次是它的第三种形态（制品新鲜度）。 |
| 13 | **门禁的启动时序假设**（full 首跑 43 步里 2 红：p12/p13）：两个门禁从**端口**学"服务起来了"，然后立刻 `grep` 一次日志；而 `sc` 是先打印 `listening`、**再**加载凭据表与 OpenSSL 上下文/证书（`apps/cli/node.mbt` 的 `sc` 启动序列）。runner 冷缓存下这个窗口比一次 grep 长——失败输出里的日志只有 `listening` 一行，**距该行出现仅 0.34 ms**（日志时间戳） | 首次手动 full 跑。**注意这是门禁的假设错，不是产品缺陷** | 新增有界等待 `wait_log`（默认 10 s，TLS 处 15 s；超时仍失败并打印日志，断言不减弱），并改掉同类站点（p12 腿 1、p12 腿 2、p13 三处、p24 明文警告）；`p5` 那条不动——它在服务跑完整场之后才查，不存在该竞态。三路单测 + 三条门禁本地回归（p12 10 腿 / p13 5 腿 / p24 4 腿）。**产品无缺陷的证据同在一次跑里**：`e2e-p24-rotation` 做完整 mTLS 轮转（换 CA、旧 CA 被拒、凭据轮换）4 腿全绿——说明 TLS 在 runner 上可用、控制面确实起来了。顺带修掉一个隐藏前置：`scripts/mfs_probe.py` 的 `str | None` 注解没有 `from __future__ import annotations`，等于**隐式要求 Python ≥3.10**（macOS 自带 3.9 直接 TypeError） |
| 14 | **`mf_editor_feed` 的 apply 应答试探误读长 JSON 应答**：LIST/CREATE 应答的首字节 `[`（91）/`{`（123）在载荷够长时通过 uleb 试探的长度上界（≤128），被解码成 `deployed pipeline "{\"name":…`——面板首刷时每行日志都成了假部署。**wbtest 的短夹具当年全绿**（49 字节的数组过不了 91 字节的读取），真页面第一条 LIST（>91 字节）才现形 | P27 真浏览器驱动阶段（合成事件绕过指针交付问题后，日志第一眼就露出假 `deployed` 行） | 修法为**解码次序**：JSON 函数集应答（数组/带 `created` 的对象）**先于** uleb 试探——二进制载荷解析 JSON 必败、自然落空；新增**长夹具**回归（>91 字节的 LIST 应答断言无 `pipeline` 键）。教训入 AGENTS P4 块：**夹具必须覆盖真实载荷的长度级别**；另留痕一个驱动环境事实：IAB 面板的指针事件（Playwright click 与 CUA 坐标）在后台不交付，页面钩子（`window.moonfluxEditor`）与合成事件是为此设计的驱动面 |

---

## 功能点简介（平台现在能做什么）

**数据面**：分区提交日志（追加 / 窗口读 / 任意偏移重放）；多分区（每分区独立日志）；段化存储（滚动、稀疏索引、retention 只删整段）；**键控压实**（删旧留新、偏移不变、空洞两侧可读）；**载荷预算**（16 MiB 批上限单一真相派生全链路，20 MiB 文件端到端逐字节一致）；**真偏移**（压实/过滤后的空洞两侧，消费显示幸存记录的真实偏移）。

**集群**：follower-pull 复制（逐分区水位 / 换主 / 分歧截断并报告丢弃量）；SC 控制面（声明式主题与放置调和、poll 驱动、单机 `serve` 与多进程 `sc + spu` 同一二进制）；消费组（协调者唯一权威、世代围栏、range 分配、托管偏移、消费地板挡 retention；**P22 起单机 serve 同一语义自任协调者**）；控制面资产下发（spec/函数集控制面持有、节点拉取、修订不回退）。

**安全面**：四角色闭合权限表（未列命令默认拒绝）、握手期认证（认证前不服务任何命令）、TLS 单向/双向（客户端强制校验、节点间加密）、凭据只做参数不入日志；**per-topic grants**（P21：授权只收窄不放宽，角色表先行；Node/Root 不受 grant 约束）与**安全审计日志**（`<data-dir>/audit.log` JSON 行：认证结果 / 权限拒绝 / 主题生命周期，凭据永不入账）。

**可编程**：mbel 表达式变换（消费路径执行、热重载、历史按当前规则重现）；版本化函数集（发布期静态检查 + 编译两道闸）；WASM 算子沙箱（ABI v1、fuel 确定性预算、失败 fail-closed）；PipelineSpec 单一真相（编辑器只是渲染器）。

**客户端与工具**：单二进制多子命令 CLI（produce / consume / serve / spu / sc / topic / group / cluster / operator / benchmark / pipeline / function-set）；WebSocket 网关（同端口同协议）；浏览器编辑器（拖拽 → 部署 → 消费；**P27 起带函数集面板/表单/选择器/漂移标记**——资产文档与协议帧全在 `apps/editor-kernel`）；**基准工具**（produce 吞吐 + 逐批延迟、consume 抽干与序号完整性校验、latency 端到端可见性——本地铁环回 ack ~4 ms / e2e p50 ~189 µs）；**MQTT 连接器**（P19）与 **Kafka 连接器**（P20：消费源 + 生产汇，手写锁定版本协议与 RecordBatch v2，CRC-32C 外部锚点验证）。

**工程面**：一内核多后端（core 在 wasm / wasm-gc / js / native 四后端编译矩阵下保持可编译）；54 步门禁（故障注入、对拍、结构断言）；**CI 已接线**（`fast` 随推送在 Linux、`full` 手动在 macOS）；golden vectors + 独立 Python 协议第二实现；54 条关键决策记录全程留痕。

---

## 维护规则

- 每轮里程碑收口时随提交更新本看板（已完成 / 待办 / 阻塞 / 返工四条道都要动）；快照日期同步。
- 本文只做**汇总与指引**：细节回链 roadmap / feature-matrix / compatibility-matrix / 决策记录 / ticket；不在此复制它们的全文（单一真相纪律，AGENTS §10）。
- 返工台账**只增不删**：返工是过程资产，删掉它等于假装没发生过。
