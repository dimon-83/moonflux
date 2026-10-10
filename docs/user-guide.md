# moonflux 实用文档（操作手册）

> **定位**：面向使用者与运维——从源码构建到跑通第一个管道，到多节点集群、安全配置与故障排查。**规约依据**：AGENTS.md §10（引用与证据规范）；**边界声明**：本文只讲"怎么用"；架构原理见 [`architecture.md`](architecture.md)，能力与状态的完整清单见 [`feature-matrix.md`](feature-matrix.md)。所有示例在 macOS/Linux + OpenSSL 环境可复现。
>
> **日期**：2026-09-25 · 对应版本：P0–P26

## 1. 构建与自检

```bash
cd ~/workspace/moonflux
moon update                         # 首次克隆必须：取 registry 索引（见下）
moon build --target native          # 产物：_build/native/debug/build/apps/cli/cli.exe
moon test --target native           # 274 项
moon test --target wasm-gc          # 174 项（内核全后端）
scripts/gates.sh                    # 全量门禁（46 步）；scripts/gates.sh fast 跳过 E2E
```

- **`moon update` 是首次克隆的前置步骤**（CI 首跑实测）：唯一的依赖 `dimon-83/mbel@0.3.3` 的**源码已随仓库 vendored** 在 `.mooncakes/`（119 个文件，随 git 追踪），但 moon 解析依赖仍要过 registry 索引——索引不在时每条 moon 命令都报 `Failed to resolve registry dependency dimon-83/mbel: module was not found in the registry`（`--frozen` 也一样失败）。moon 自己会提示 `you may need to run 'moon update'`。
- **工具链必须与 CI 同版本**（决策 51）：CI 装 MoonBit 的 `latest`（版本化下载 URL 被 CDN 403，钉不住旧版），仓库的格式以该版本为准——两个格式器方向相反（新版给结构体字面量补尾随逗号、旧版删掉），因此**旧版本地工具链会让 `moon fmt --check` 朝相反方向报红**，`moon info` 也会把这些 `.mbti` 改回去。升级一条命令：`moon upgrade`（升级后重跑 `scripts/gates.sh fast` 确认 12 步绿）。

- CLI 是**单二进制多子命令**：`serve`（单机 all-in-one）、`spu`（数据节点）、`sc`（控制面）加上各运维子命令，都从同一个 `cli.exe` 出。
- 门禁脚本默认测 **debug** 构建（`moon build --target native` 的产物）；`MOONFLUX_EXE` 可指向任意构建，但别把门禁指向一个碰巧存在的旧 release——它曾让一次门禁跑在上一轮的二进制上。

## 2. 五分钟上手：单机管道

```bash
# 1) 一份管道 spec：文件源 → 主题 → stdout
cat > demo.json <<'EOF'
{
  "apiVersion": "moonflux.io/v1alpha1",
  "kind": "Pipeline",
  "metadata": { "name": "demo" },
  "spec": {
    "source": { "type": "file", "path": "in.txt" },
    "transforms": [],
    "topic": { "name": "events" },
    "sink": { "type": "stdout" }
  }
}
EOF
printf 'hello\nworld\n' > in.txt

# 2) 起一个单机 broker（data-dir 存日志与元数据）
cli.exe serve --data-dir .moonflux-data --listen 127.0.0.1:19420 &

# 3) 应用管道（发布期静态检查：语法/未知函数/未知变量/类型错误在此拦截）
cli.exe pipeline apply -f demo.json --data-dir .moonflux-data

# 4) 生产与消费
cli.exe produce --topic events --file in.txt --remote 127.0.0.1:19420
cli.exe consume --topic events --remote 127.0.0.1:19420
#  0	<ts>		hello
#  1	<ts>		world
```

规则热重载：改完 spec 再 `apply` 即可，`serve` 按 `topology.json` 的纳秒 mtime 自动换入，**无需重启**；带表达式的变换作用于消费/回放路径，所以**历史数据按当前规则重现**。

**大文件与大记录（P15）**：`produce` 对文件大小没有人为上限——记录按 4 MiB 一批发送（本地与远端同一套逻辑），偏移在到达序上连续，所以一次发送仍然只报一个区间；消费端按服务端给出的窗口推进，`consume` 会把一个分区**读干**再退出（不再有"一次最多读一百万条"的静默截断）。两条硬边界要知道：单条记录的 key/value 上限 4 MiB（生产者在自己进程里**按名字**拒绝，不会丢给服务端报 `ValueTooLarge`），一个批帧上限 16 MiB（服务端超限时给结构化拒绝并在日志里写明）。批之间**不保证原子**：第 3 批失败时前 2 批已经落盘——这是至少一次口径的推论。

**基准（P17）**：`benchmark produce|consume|latency --topic T [--data-dir D | --remote host:port]` 给数据面立吞吐/延迟基线——produce 报吞吐与逐批延迟直方图（`--records/--record-size/--batch-records`），consume 抽干并可用 `--verify` 校验每条值的序号头（负载下的完整性检查），latency 报 produce-ack 与 produce→consume 可见性两组直方图（`--samples`）。输出是可 grep 的 `key=value` 行；计时用单调微秒时钟。**数字是报告不是门禁**（决策 41）——同一批数据不能在空闲笔记本上过、在满载 CI 上红。改了服务端循环之后跑一次 `benchmark latency` 是最便宜的回归检查：P17 就是用它抓到「每请求 ~200 ms」的 accept 税的。

**主题与消费组，两种形态（P18）**：`topic create/list/delete` 对 `--remote <serve>`（单机）与 `--remote <sc>`（集群）都可用。单机形态：声明写入 broker 自己的元数据（与其函数集同库）；`topic list` 列**声明 ∪ 自动创建**（produce 建的主题不漏报）；`topic delete` **连带删除数据**（日志句柄先失效再删文件，重新生产从 offset 0 开始）；`--replication-factor > 1` 被拒绝——一个节点谈不了副本。**消费组需要控制面**：对 serve 发组命令会得到解释性拒绝（指出跑 sc + spu 集群），不再是 `unknown command`。另外，空洞日志（压实/过滤之后）的消费在三条路径上都显示**幸存记录的真实偏移**（P18 修正：此前空洞之后的偏移会整体错位）。

**MQTT 连接器（P19）**：spec 的源/汇可以是 MQTT——`{"type":"mqtt","url":"mqtt://[user:pass@]host[:port]/topic"}`。**源是订阅**：`pipeline run` 首拉建连并订阅，之后按批把消息追加进主题再出汇——与一次性源（file/stdin/http）不同，**它不会自己退出**（流式运行，Ctrl-C 停止）；`Quiet` 时安静等待，消息到了就交付。**汇是发布**：每条记录的值发到 URL 的 topic。边界（决策 43）：订阅与发布均 QoS 0（订阅 QoS 0 时 broker 按 min 降级送出）；不做 TLS / 遗嘱 / 保留消息 / 自动重连——断线是结构化错误，重启 run 即重连；URL 内嵌凭据会随 spec 落入 `topology.json`，请用受信网络或 broker 侧 ACL。本地自测可用任意 MQTT broker（如 mosquitto：`mosquitto -p 1884`）；`scripts/e2e-p19-mqtt.sh` 里的 `scripts/mqtt_test_broker.py` 就是最小可用的测试 broker。

### 无重启轮转（P24）

证书过期与凭据变更不需要重启：**替换磁盘上的文件**（证书/私钥/CA，或 `<data-dir>/auth.json`），服务端在下一秒的检查中自动换入新材料。

- **新连接**用新证书与新凭据表；**已建立的连接**不受影响（保留其证书与已认证身份，直到自然断开）。
- 换坏了的文件不会宕机：服务端保留旧材料继续服务，并在 stderr 警告（启动时才是 fail-fast）。
- 观察重载：serve/sc/spu 的日志会出现 `TLS context rotated` / `credentials reloaded` 行。
- **认证开启但监听是明文**时，启动日志会明确警告凭据走明文——请加 `--tls-cert/--tls-key` 或在受信本地目录去掉 auth.json。
- 免信号垫片、跨平台，与 cert-manager 等"替换挂载密钥"的轮转流程天然契合。

### 沙箱标量函数（ABI v2，P26）

"用户提交的标量函数"跑在 WASM 沙箱里：模块导出可选的 v2 标量入口，节点注册表把函数名绑到模块，spec 用 `{"type":"scalar","function":"<名>"}` 变换逐记录调用。

```bash
# 1. 节点注册表：<data-dir>/scalar-functions.json
cat > .moonflux-data/scalar-functions.json <<'JSON'
{"revision":1,"functions":[
  {"name":"shout","module":"/path/operator-scalar.wasm","tier":"user","max_calls_per_batch":100000}
]}
JSON

# 2. spec 里引用函数名（apply 时解析绑定；未注册名或 v1-only 模块在这里被拒）
#    transforms: [{"type":"scalar","function":"shout"}]
```

- 记录值以**字符串**传给函数；函数**显式声明参数类型**（string/number/bool/array），类型不符是结构化拒绝（fail-closed，无半批输出）。
- **每批调用上限**按每次链调用拿到的记录数计（`pipeline run` 整批；serve 取数路径逐条目——上限在那条路上恒不触发，真正的界是每次一条）。
- sandbox 无导入（无时钟/无 IO/无随机）：确定性是结构事实，探针按 WAT 真相源查。
- 与 mbel 的差异：mbel 函数按调用点推断类型、属**可信资产**；标量函数必须**显式声明**类型，属**不受信输入**。两条路径的输出可互为参照（门禁里有逐字节对拍）。

**Kafka 连接器（P20）**：spec 的源/汇可以是 Kafka——`{"type":"kafka","url":"kafka://host:port/topic[?partition=N&from=earliest|latest|<offset>]"}`。**源是消费**：`pipeline run` 首拉建连、解析元数据与起始偏移（默认 earliest），之后每拉一轮从 broker 取一批——同样是**流式运行**（Ctrl-C 停止），空应答是安静、不是结束。**汇是发布**：每批记录打成一个 RecordBatch v2 发到 URL 的分区（默认 0），acks=1。**压缩（P25）**：产生端可在 URL 加 `?compression=gzip`（RecordBatch 以 gzip 容器压缩，真实 broker 生产者的默认形态）；读取端按批的压缩列行动——gzip 批解压后解析，snappy/lz4/zstd **仍按 codec 名拒绝**，未知 codec 在 apply 期拒绝。解压输出以单一批预算为上界（炸弹防护）。**边界（决策 44）**：**无消费组**（偏移在本进程内存里，重启按 `from` 重开）、无幂等/事务、无 TLS/SASL。连上先做版本探针：broker 不支持锁定的协议版本会在**连接期**按名报错。本地自测需一个真实 broker（本仓库门禁用 `scripts/kafka_test_broker.py` 这个最小实现）。

**spec 形态**（`core/spec::parse_spec` 是唯一权威）：

| 字段 | 取值 |
| :--- | :--- |
| `spec.source.type` | `file`（配 `path`）· `http`（配 `url`，http/1.1；可选 `interval_ms`：0/缺省 = 一次性 GET，正数 = 按间隔轮询，轮询时不返回 `Exhausted` 而返回 `Quiet`）· `stdin` |
| `spec.transforms[].expr` | mbel 表达式（可选 `functions`：按名引用函数集） |
| `spec.transforms[].operator` | wasm 算子文件路径（配 `config`，原样透传给算子） |
| `spec.topic.name` | 主题名（白名单校验，`core/spec::valid_topic_name`） |
| `spec.sink.type` | `stdout` · `http`（配 `url`） |

## 3. 最小集群：1 控制面 + 2 数据节点

```bash
cli.exe sc  --listen 127.0.0.1:19451 --data-dir sc-data &
cli.exe spu --id spu-a --listen 127.0.0.1:19452 --data-dir a-data --sc 127.0.0.1:19451 &
cli.exe spu --id spu-b --listen 127.0.0.1:19453 --data-dir b-data --sc 127.0.0.1:19451 &

# 集群口径：管道与主题声明发给控制面，数据节点经心跳拉取
cli.exe pipeline apply -f demo.json --remote 127.0.0.1:19451
cli.exe topic create --name events --partitions 3 --replication-factor 2 --remote 127.0.0.1:19451

cli.exe cluster status --remote 127.0.0.1:19451
# 逐分区：leader / replicas / hw / leo
cli.exe cluster leader  --topic events --partition 0 --remote 127.0.0.1:19451
cli.exe cluster offsets --topic events --partition 0 --remote 127.0.0.1:19452   # 问 leader
```

- **放置与选主都是控制面的决定**：节点只上报、只采纳；写入只认 leader，打错节点会得到带 leader 地址的结构化拒绝。

### 3.1 观测平表与连接档案（P23）

```bash
# 每分区一行：谁领导、谁持有、走到哪了（集群与单机 serve 同一命令）
cli.exe partition list --topic events --remote 127.0.0.1:19451

# 节点与其承载（集群）：注册表 + 逐分区放置视图组合出的承载计数
cli.exe cluster spu list --remote 127.0.0.1:19451
```

- `partition list` 是**组合不是第二个权威**：每个分区的 hw/leo 就是该分区 leader 对
  `cluster offsets` 的回答，门禁断言两者逐分区一致。
- `spu list` 不含每节点磁盘字节——那需要节点上报（协议加法段），缺位留痕而非拿 leader
  侧字节冒充。

```bash
# 命名连接档案：不再每次裸传 --remote
cli.exe profile add local --remote 127.0.0.1:19451   # 首个档案自动成为 current
cli.exe partition list --topic events                # 无 --remote 时用 current profile
cli.exe profile list                                 # current 带 * 标记
cli.exe profile use other                            # 切换
cli.exe profile remove local                         # 移除
```

- 解析顺序：**显式 `--remote` 优先 → current profile → 报错**（错误文本会说明三条路）。
- 配置文件：`$MOONFLUX_CONFIG`（测试/CI 隔离用）或 `~/.moonflux/config`；原子写、损坏即报错、
  未知字段拒绝。
- **档案不是凭据库**：携带 `token` 的档案在加载期按名拒绝——凭据走 `--token` 或
  `MOONFLUX_TOKEN`，不会有第三条静默口径。
- 本地/远端模式不受档案影响：`produce/consume/benchmark` 的本地模式由"是否带 `--remote`"
  决定，档案不会隐式把人切进远端。
- 分区是复制的单元：3 分区 RF=2 时，杀掉一个节点只停它持有的分区，其余分区照常推进；新 leader 由最小滞后副本自我提升（提名随心跳下发）。
- 数据节点离开控制面也能跑（自持已应用管道的 partition 0），日志会写明这是退化自放置。

## 4. 消费组（至少一次）

集群（`sc + spu`）与**单机 `serve`**（P22）支持完全相同的消费组语义——serve 自任协调者，成员与门禁分辨不出对端是谁；`--remote` 指向 serve 的监听地址即可。

```bash
# 两个成员组队消费 3 个分区（range 分配，世代围栏）
cli.exe consume --topic events --remote 127.0.0.1:19451 --group g1 --member m1 --follow --commit-ms 500
cli.exe consume --topic events --remote 127.0.0.1:19451 --group g1 --member m2 --follow --commit-ms 500

cli.exe group list     --remote 127.0.0.1:19451
cli.exe group describe --name g1 --remote 127.0.0.1:19451      # 滞后为观测值
cli.exe group commit   --group g1 --member m1 --topic events --partition 0 \
                       --offset 7 --remote 127.0.0.1:19451      # 与成员同一围栏，无特权路径
```

- **空闲也要心跳**（`--follow` 期间自动进行）：静默成员被按存活超时清扫，其分区立即重分配。
- 语义是**至少一次**：提交在处理之后，重复允许、缺口不允许；再平衡窗口内两个成员可能短暂同读一个分区。
- 消费组有提交的分区参与 retention 下界（最慢消费者挡住删除）；从未提交的组不算"落后"。单机 serve 的 compact 与 retention 同样接组地板（`min(自身末端, 组地板)`）。
- **单机 serve 的分区来源是"声明 ∪ 磁盘"**：produce 自动创建的主题（从未 `topic create`）一样能被组消费——份额按磁盘上实际存在的分区分配。
- 成员凭据与所有 CLI 命令同一口径：`--token` 优先，`MOONFLUX_TOKEN` 环境变量兜底。

## 5. 可编程：表达式、函数集与算子

**表达式变换**（mbel，消费/回放路径逐条执行）：

```json
{ "expr": "upper(value)", "functions": "text-fns" }
```

**函数集**（版本化规则资产）：

```bash
cat > fns.json <<'EOF'
{"name":"text-fns","functions":[{"name":"shout","params":["x"],"body":"upper(x) + \"!\""}]}
EOF
# 本地口径：资产直接落进这个 data dir 的元数据（不需要先起服务）
cli.exe function-set create --file fns.json --data-dir .moonflux-data
cli.exe function-set list   --data-dir .moonflux-data
# 远端口径：请一个正在运行的节点安装（两者互斥，同时给会按名拒绝）
cli.exe function-set create --file fns.json --remote 127.0.0.1:19451
cli.exe function-set list   --remote 127.0.0.1:19451
```

- **两个宿主，同一份话**：本地路径直接复用节点侧的 handler，所以 `--data-dir` 的应答与服务器会发的字节相同；`--remote` 与 `--data-dir` 同时给按名拒绝（那是两句不同的话，P30/T107、决策 56）。
- 名字/参数/函数体以 mbel 的规则为唯一权威；**函数体含 `now` 在部署被拒**（确定性红线：重放必须同输入同输出）。
- spec 按名引用；**更新集合必须 re-apply 才生效**（解析到的 revision 记入 `topology.json`，运维可见漂移）。
- 引用缺失集合、使用集合外名字、类型错误，都在 `apply`（发布期）拦截，不进运行期。

**wasm 算子**（沙箱，guest 无 IO/时钟）：

```bash
cli.exe operator verify  --file operator.wasm        # ABI/导入段/空批耗时检查
cli.exe operator describe --file operator.wasm       # 预算 tier 与墙钟观测（report-only）
# spec: {"operator": "operator.wasm", "config": {...}}   config 原样透传，宿主不解释语义
```

失败 fail-closed：trap / 拒绝 / 超预算（记录数 + fuel）都是结构化错误，**半批绝不落 Sink**。

## 6. 安全面配置

**认证**（默认关闭但启动明示；`auth.json` 放在各进程的 data-dir）：

```json
{"credentials":[
  {"name":"root",  "token":"root-token-123456",  "role":"root"},
  {"name":"spu-a", "token":"spu-a-node-token",   "role":"node"},
  {"name":"alice", "token":"alice-secret-1234",  "role":"read-write"},
  {"name":"bob",   "token":"bob-secret-123456",  "role":"read-only"}
]}
```

- 角色：`root`（全部）· `read-write`（数据面 + 自己的消费组）· `read-only`（只读）· `node`（仅节点间命令：注册/心跳/复制/确认/资产拉取）。
- **节点命令只有 `node` 角色能发**：能伪造 `SYNC_ACK` 就能推动所有人的 committed read 依赖的水位——节点凭据的泄漏等价于节点身份被冒用。
- token ≥ 8 字符；token 是**参数**（`--token`，环境变量 `MOONFLUX_TOKEN` 兜底），内核从不自己读凭据。
- 凭据不会出现在日志里（门禁有专腿 grep）。

**TLS**（OpenSSL 运行时加载；机器没有 libssl 只失去 TLS，不失去服务端）：

```bash
# 服务端（serve/spu/sc 通用）：证书开 TLS；加 CA + require-client 即双向
cli.exe serve --listen 127.0.0.1:19420 --data-dir d \
  --tls-cert sc.pem --tls-key sc.key --tls-ca ca.pem --tls-require-client

# 客户端：给了 CA 就是 TLS，且强制校验（VERIFY_PEER + 主机名钉住）
cli.exe topic list --remote 127.0.0.1:19420 --token root-token-123456 \
  --tls-ca ca.pem --tls-cert client.pem --tls-key client.key
```

| flag | 作用 | 环境变量回退 |
| :--- | :--- | :--- |
| `--token T` | 展示的凭据（角色由服务端凭据表决定） | `MOONFLUX_TOKEN` |
| `--tls-ca P` | 信任锚；**出现即启用 TLS**（没有"开关"：没有锚就没有可默认的信任） | `MOONFLUX_TLS_CA` |
| `--tls-cert P` / `--tls-key P` | 本进程证书/私钥（双向 TLS 时必需；节点同时用它服务自己） | `MOONFLUX_TLS_CERT` / `MOONFLUX_TLS_KEY` |
| `--tls-require-client` | 仅服务端：要求对端出示证书 | — |

## 7. 存储运维

```bash
cli.exe cluster segments --topic events --remote 127.0.0.1:19452   # 段视图
cli.exe cluster compact  --topic events --remote 127.0.0.1:19452   # 一次键控压实（每个副本各做一次）
cli.exe produce --topic events --file events.txt --key-separator ':' --remote 127.0.0.1:19452
```

| 环境变量 | 作用 | 缺省 |
| :--- | :--- | :--- |
| `MOONFLUX_ROLL_BYTES` / `MOONFLUX_ROLL_MS` | 段滚动阈值（字节 / 时长） | 关闭（单段） |
| `MOONFLUX_RETAIN_BYTES` / `MOONFLUX_RETAIN_MS` | retention 策略 | 关闭 |
| `MOONFLUX_INDEX_EVERY` | 索引锚点密度 | 内置值 |
| `MOONFLUX_COMPACT_MS` | 后台压实的节拍（**即开关**） | 关闭（0） |
| `MOONFLUX_COMPACT_MIN_DIRTY_BYTES` | 后台压实愿意为多少可弃字节重写一段 | 0（有可弃即重写） |

- 段边界永远是帧边界；只有最后一段可能带撕裂尾（崩溃恢复截断并报告）。
- **retention 只删整段、只删 floor 以下**：floor = `min(leader 已提交前缀, 最慢消费组的提交偏移)`；删完后更老的读得到 `OffsetOutOfRange`（"没了"≠"空"）。每次删除打印段 base/记录数/字节数与新可读起点。
- `.idx` 损坏不用修：任何疑点自动回退全扫，结果与有索引逐字节一致。
- **压实（compaction，P14）删被取代的键、不搬存活记录**：`cluster compact` 只删除「同一键有更新版本」的记录，存活记录**保留原偏移**（读取与消费偏移因此不受影响），空洞可以正常读；只动已提交前缀（floor = `min(leader 水位, 消费组地板)`）之下的封存段，每次删除打印逐段与总计，重复执行为空报告。**P28 起可以后台化**：给 serve/spu 设 `MOONFLUX_COMPACT_MS`（如 300000 = 每 5 分钟尝试一次），压实就与 retention 共用同一套节拍、同一 floor 自动运行——节拍即开关（不设 = 永不自动压实），`MOONFLUX_COMPACT_MIN_DIRTY_BYTES` 控制「多少可弃字节才值得重写一段」。floor 之上被超越的记录**不会**被后台压实碰（那是消费组还没读到的数据）。
- **每个副本都要压实**：命令是节点本地的存储动作，请对**持有该分区的每个节点**各执行一次（只压 leader 会让故障切换时复活已删的键）；复制的空洞由副本自行跨过并在日志里说明。
- 键由 `produce --key K`（全部同键）或 `--key-separator S`（每行首个分隔符拆 key/value；无分隔符的行**跳过并在 stderr 汇总**）产生；`consume` 第三列即键。

## 8. Web 编辑器

```bash
cli.exe serve --data-dir d --listen 127.0.0.1:19420 --ws
# 浏览器打开 http://127.0.0.1:<port>/ —— 与 CLI 同端口、同一协议（WS 升级）
```

拖拽 Source/Transform/Sink → 部署（`CMD_APPLY_PIPELINE`）→ 在编辑器内消费。编辑器是 spec 的渲染器：它产出的就是 `PipelineSpec`，CLI 与浏览器看到同一个真相。

**函数集面板（P27）**：连接后左侧「function sets」列出节点上的集合（名称 / revision / 函数数），可刷新、删除、载入表单；「new set」打开编辑表单（集合名 + 函数行：name / params 逗号分隔 / body / description），「deploy set」即 `function-set create` 的线上等价（经 WS，命令 22–25）。表达式节点多一个「function set」下拉（— 无 — + 已知集合），选择随图进入 `build_spec` 的 `transforms[i].functions`。**修订漂移标记**：每次部署成功会快照所引用集合的 revision；之后任何一次刷新发现集合前进，该行出现 `↻ re-apply (applied r{旧} · now r{新})`——重新部署即换绑（服务端权威记录是 `<data-dir>/topology.json` 的 `functions` 数组，标记只是编辑器侧提醒）。**两条边界**：表单只做形状预检，mbel 规则与纯度以节点发布期门禁为准（拒绝原样进日志）；UI 不提供标量函数编写面（那是 ABI v2 沙箱的路径）。认证开启时函数集命令仅 Root 可用（闭合权限表），编辑器会话不带凭据——函数集 UI 的口径与编辑器整体一致：本地/免认证姿态。

## 9. 实战：五个端到端例子

以下例子都在本机跑过，输出的形状与这里一致（值为一次真实运行的截取）。它们逐级组合前面的能力：表达式 → 函数集 → 算子沙箱 → 分区与消费组 → 集群容错 → 安全拓扑。

> **先过四条表达式的硬边界**（全部实测——踩中任何一条都会在 `apply` 期被拒，而不是等运行期）：
> 1. **条件表达式的语法取决于位置**。顶层三元 `?:` 只在条件是比较/二元表达式时可用（`value == "x" ? a : b`、`len(value) > 2 ? a : b` ✓）；**条件是函数调用时编译报 `Token ?`**，加一个比较即可（`hasSuffix(value, "a") == true ? a : b` ✓），或把条件逻辑搬进函数体。顶层 `if {}` 不合法（`Token value`）；**函数体里 `?:` 与 `if cond { a } else { b }` 都可用**，条件可以是任意表达式——所以惯例是：条件逻辑写进函数集，顶层只做调用与拼装。
> 2. **发布期静态检查用探针求值**（`value="a"`、`timestamp` 为数字、`headers_count=0`），表达式必须对**任意字符串**成立。越界访问要自己守卫：`if len(split(line, " ")) > i { ... } else { "" }`，否则越界返回 null、`trim(null)` 被拒。
> 3. **`get(array, index)` 只认浮点索引**：`get(arr, 0)` 与 `get(arr, int(i))` 都走 fallback 返回 null（mbel 的 parity wart），要用 `i * 1.0` 强制成浮点。
> 4. **字符串拼接用 `+`**（`concat` 是数组拼接），**`functions` 引用挂在每个用到它的 transform 上**（不是 spec 全局）。

### 9.1 日志富化：多级表达式 + 函数集

一条流水线把原始 access log 变成带级别的运维行。输入 `access.log`：

```
GET /api/users 200 12
POST /api/orders 201 340
GET /static/logo.png 200 3
GET /api/search 500 4800
DELETE /api/orders/7 204 95
```

函数集 `weblog`（条件逻辑都在这里）：

```json
{"name":"weblog","functions":[
  {"name":"field","params":["line","i"],
   "body":"if len(split(line, \" \")) > i { trim(get(split(line, \" \"), i * 1.0)) } else { \"\" }"},
  {"name":"status_class","params":["code"],
   "body":"hasPrefix(code, \"2\") ? \"ok\" : (hasPrefix(code, \"4\") ? \"client-error\" : (hasPrefix(code, \"5\") ? \"server-error\" : \"other\"))"},
  {"name":"is_static","params":["path"],
   "body":"hasSuffix(path, \".png\") || hasSuffix(path, \".css\") || hasSuffix(path, \".js\")"},
  {"name":"severity","params":["line"],
   "body":"if hasPrefix(field(line, 2), \"5\") { \"ALERT\" } else { if hasPrefix(field(line, 2), \"4\") { \"WARN\" } else { \"INFO\" } }"},
  {"name":"decorate","params":["line"],
   "body":"severity(line) + \" \" + status_class(field(line, 2)) + \" \" + (is_static(field(line, 1)) ? \"static\" : \"api\") + \" | \" + field(line, 0) + \" \" + field(line, 1) + \" took \" + field(line, 3) + \"ms\""}
]}
```

spec（两个表达式阶段：先归一化，再富化）：

```json
{
  "apiVersion": "moonflux.io/v1alpha1",
  "kind": "Pipeline",
  "metadata": { "name": "weblog-enrich" },
  "spec": {
    "source": { "type": "file", "path": "access.log" },
    "transforms": [
      { "type": "expr", "expr": "trim(value)" },
      { "type": "expr", "expr": "decorate(value)", "functions": "weblog" }
    ],
    "topic": { "name": "web-events" },
    "sink": { "type": "stdout" }
  }
}
```

```bash
# 在放 access.log 的目录里执行：spec 里的 source.path 与算子 module 一样，
# 都是**进程工作目录**相对路径
cli.exe serve --data-dir d --listen 127.0.0.1:19520 &      # 函数集是节点本地资产，先起服务
cli.exe function-set create --file weblog.json --remote 127.0.0.1:19520
cli.exe pipeline apply -f weblog-spec.json --data-dir d
cli.exe pipeline run --data-dir d
```

```
INFO ok api | GET /api/users took 12ms
INFO ok api | POST /api/orders took 340ms
INFO ok static | GET /static/logo.png took 3ms
ALERT server-error api | GET /api/search took 4800ms
INFO ok api | DELETE /api/orders/7 took 95ms
```

发布期的拦截同一套资产就能看到（`apply` 而非运行时）：

| 写法 | 结果 |
| :--- | :--- |
| `decorate(value)` 但 transform 没写 `"functions": "weblog"` | `static check: Jexl Function field is not defined` |
| 用集合里没有的名字，如 `nosuch(value)` | `function set weblog: ... no such function`（名字与类型都在 apply 期拦） |
| 函数体含 `now` | 部署期被拒（确定性红线：重放必须同输入同输出） |
| 顶层写 `hasSuffix(value,"png") ? … : …`（条件是调用） | `compile: Token ?`——改成 `hasSuffix(value,"png") == true ? … : …` 或搬进函数体（见边界 1） |

规则调优**不需要重启**：改 `decorate` 的阈值/前缀 → `function-set create`（revision +1）→ `pipeline apply`（重新绑定）→ 下一个请求就生效；`topology.json` 里记着绑定的 revision，漂移可见。

### 9.2 沙箱算子的批语义与 fail-closed

算子（wasm）是**批级**节点，表达式是**记录级**节点，两者可以在同一条链上混用：

```json
{
  "transforms": [
    { "type": "expr", "expr": "trim(value)" },
    { "type": "wasm", "module": "_build/wasm/debug/build/apps/operator-upper/operator-upper.wasm" }
  ]
}
```

`module` 是**节点进程当前目录**可见的路径（上面是仓库根目录下的构建产物），`config` 是 JSON 对象**原样透传给 guest**（宿主不解释语义）。上面的链输出 `GET /API/USERS 200 12`——先按记录 trim，再整批大写。

失败是 **fail-closed** 且**半批不落地**。把 `operator-fixture` 配成拒绝模式（`{"mode":"refuse"}`），先生产再消费：

```
$ cli.exe produce --topic guard --file access.log --remote 127.0.0.1:19521
produced 5 records to topic guard[0] at offsets 0..5

$ cli.exe consume --topic guard --remote 127.0.0.1:19521
（stdout 为空）
$ echo $?
error: fetch: Server(code=5, transform: wasm: GuestTrap(operator fixture-refuse: fixture refused this batch on purpose))
```

记录**已经安全落盘**（0..5），消费者拿到的是结构化错误与 guest 给出的原因——不是"读到一半"。同一模块换成 `{"mode":"identity"}` 即刻恢复可读，`{"mode":"trap"}` / `{"mode":"spin"}` 分别演示失控失败与死循环（后者被 fuel 预算拦下，墙钟只报耗时）。预算与 ABI 细节见 [`cli-roadmap.md`](cli-roadmap.md) 与架构 §8。

### 9.3 分区路由 + 消费组：两个成员分担，坏一个自动接管

按业务分区的经典用法（把分区当分片：`--partition 0/1/2` 由写入方决定）：

```bash
# 3 分区 RF=1 的 orders，两个节点分摊 leader
cli.exe sc  --listen 127.0.0.1:19601 --data-dir sc-data &
cli.exe spu --id spu-a --listen 127.0.0.1:19602 --data-dir a-data --sc 127.0.0.1:19601 &
cli.exe spu --id spu-b --listen 127.0.0.1:19603 --data-dir b-data --sc 127.0.0.1:19601 &
cli.exe topic create --name orders --partitions 3 --replication-factor 1 --remote 127.0.0.1:19601

# 写入方按分片寻址（先问 leader，再写它）
L=$(cli.exe cluster leader --topic orders --partition 0 --remote 127.0.0.1:19601)
cli.exe produce --topic orders --partition 0 --file p0.txt --remote "$L"
```

两个成员加入同一个组（各自一个终端，`--follow` 会持续心跳与按间隔提交）：

```bash
cli.exe consume --topic orders --group billing --member m1 --remote 127.0.0.1:19601 --follow --commit-ms 300
cli.exe consume --topic orders --group billing --member m2 --remote 127.0.0.1:19601 --follow --commit-ms 300
cli.exe group describe --name billing --remote 127.0.0.1:19601
```

```
group billing	epoch=3
  member m1	cli:39585
  member m2	cli:39590
  orders[0]	committed=4	lag=0
  orders[1]	committed=4	lag=0
  orders[2]	committed=4	lag=0
```

杀掉 m1（`kill`，不是优雅退出——模拟崩溃）：

```
group billing	epoch=4
  member m2	cli:39590
  orders[0]	committed=4	lag=0
```

**世代（epoch）从 3 走到 4**：成员集合变了才换代，幸存者在心跳应答里学到新分配，从**已提交偏移**续读。语义是**至少一次**：重复允许、缺口不允许；`lag` 是观测值（由 CLI 向各分区 leader 现问）。精确的无缺口断言在 `scripts/e2e-p9-groups.sh`（12 条生产 / 18 次投递、成员死亡后接管、过期世代提交被拒）。

### 9.4 集群容错：RF=2 下杀 leader 会发生什么

3 节点、3 分区、RF=2，每个分区一个 leader 一个 follower。准备就绪时：

```
[0] leader=127.0.0.1:19703 replicas=127.0.0.1:19703,127.0.0.1:19704 hw=3 leo=3
[1] leader=127.0.0.1:19704 replicas=127.0.0.1:19704,127.0.0.1:19702 hw=3 leo=3
[2] leader=127.0.0.1:19702 replicas=127.0.0.1:19702,127.0.0.1:19703 hw=3 leo=3
```

杀掉 `[0]` 的 leader（19703）后：

```
[0] leader=127.0.0.1:19704 replicas=127.0.0.1:19703,127.0.0.1:19704 hw=0 leo=3
[1] leader=127.0.0.1:19704 replicas=127.0.0.1:19704,127.0.0.1:19702 hw=3 leo=3
[2] leader=127.0.0.1:19702 replicas=127.0.0.1:19702,127.0.0.1:19703 hw=3 leo=3
```

四件事同时发生，都可从这一屏读出来：① 换主（19704 自我提升，SC 只提名）；② **水位塌到 0**——`HW = min(LEO)` 而副本集合里仍有点不亮的 19703，提交语义因此**停住**（这是设计，不是故障）；③ 记录没丢（`leo=3`）；④ 邻居分区毫发无损（**隔离以分区为单位**）。

水位塌陷时两种读的差别正好演示语义：

```bash
cli.exe consume --topic metrics --partition 0 --remote 127.0.0.1:19704              # 未提交读（默认，≤ LEO）
0	1789709606505		p0-m1
1	1789709606505		p0-m2
2	1789709606505		p0-m3

cli.exe consume --topic metrics --partition 0 --committed --remote 127.0.0.1:19704  # 提交读（≤ HW）
（没有输出——HW 是 0）
```

把节点拉回来（同一 `--data-dir`，日志与身份都在）：

```
replicating metrics[0] from 127.0.0.1:19704; caught up to 3
[0] leader=127.0.0.1:19704 replicas=127.0.0.1:19703,127.0.0.1:19704 hw=3 leo=3   ← 水位恢复
```

控制面的日志给出完整因果链（`node spu-b is offline (no heartbeat within 3000ms)` → `offering metrics[0] to … (least lagging eligible replica; previous leader … is gone)` → `elected … leader of metrics[0]`）。回归时若本地尾巴超出了新 leader 的 LEO，会**按分区截断到帧边界并报告丢弃**——见 `scripts/e2e-p7-partitions.sh` 的重归腿。

### 9.5 安全的生产拓扑：三个身份 + 双向 TLS

一个控制面、一个数据节点，端口全部 TLS（要求客户端证书），凭据表四类角色：

```json
{"credentials":[
  {"name":"root",  "token":"root-token-123456", "role":"root"},
  {"name":"spu-a", "token":"spu-a-node-token",  "role":"node"},
  {"name":"app",   "token":"app-secret-123456", "role":"read-write"},
  {"name":"dash",  "token":"dash-secret-1234",  "role":"read-only"}
]}
```

```bash
# 服务端：证书开 TLS，配 --tls-require-client 即双向（节点之间也走同一套）
cli.exe sc  --listen 127.0.0.1:19801 --data-dir sc-data   --tls-cert sc.pem --tls-key sc.key --tls-ca ca.pem --tls-require-client &
cli.exe spu --id spu-a --listen 127.0.0.1:19802 --data-dir a-data --sc 127.0.0.1:19801   --token spu-a-node-token   --tls-cert spu-a.pem --tls-key spu-a.key --tls-ca ca.pem --tls-require-client &

# 管理员：root 凭据 + 客户端证书
cli.exe topic create --name events --partitions 3 --replication-factor 1   --remote 127.0.0.1:19801 --token root-token-123456   --tls-ca ca.pem --tls-cert admin.pem --tls-key admin.key

# 应用：只能写数据面
cli.exe produce --topic events --file in.txt --remote 127.0.0.1:19802   --token app-secret-123456 --tls-ca ca.pem --tls-cert app.pem --tls-key app.key

# 看板：只能读
cli.exe consume --topic events --remote 127.0.0.1:19802   --token dash-secret-1234 --tls-ca ca.pem --tls-cert dash.pem --tls-key dash.key
```

每个身份的**越权会被结构化拒绝**（`code 10`），改不了数据面语义：

| 尝试 | 结果 |
| :--- | :--- |
| 看板身份 `produce` | `code 10 dash (read-only) may not issue command 3` |
| 看板身份 `topic delete` | `code 10 …may not issue command 17` |
| 应用身份伪造 `CMD_REGISTER`（用 `scripts/mfs_probe.py`） | `code 10 app (read-write) may not issue command 7` |
| 不带 `--token` | `code 9 authenticate first` |
| 不带客户端证书（服务端 require-client） | 握手失败：`peer did not return a certificate` |
| 用别的 CA 签的证书 | `certificate verify failed (code 20)` |
| 明文客户端打 TLS 端口 | 连接被拒（服务端记 `wrong version number` 并继续服务） |

**为什么节点身份是单独一类**：它能发 `SYNC_ACK`，而水位是 `min(LEO)`——伪造一个确认就能推动所有人提交读依赖的高水位。所以 `--token` 给应用的是 `read-write`，绝不给 `node`。完整拒绝矩阵与对拍见 `scripts/e2e-p12-security.sh`（7 条腿，含 TLS 下复制逐字节一致）。

## 10. 故障排查

| 症状 | 大概率原因 / 处置 |
| :--- | :--- |
| `authenticate first`（code 9） | 服务端配了 `auth.json` 而客户端没带 `--token`；或 token 不在凭据表 |
| `may not issue command N`（code 10） | 角色权限不足。数据写要 `read-write`+；集群/主题/函数集管理要 `root`；`N` 对照 `core/client::CMD_*` 常量 |
| `certificate verify failed (code 20)` | 客户端 CA 与服务端证书不匹配（校验在起作用）；核对 `--tls-ca` 与证书签发链、主机名 |
| `Io(errno=54 Connection reset by peer, op=recv)` | 对端是 TLS 端口而本端发的明文（或反之被服务端拒绝后重置）——补 `--tls-*` flags |
| `TLS handshake failed`（服务端日志） | 服务端要求客户端证书（`--tls-require-client`）而对端没带；看服务端日志里的 OpenSSL 原文 |
| 节点反复 `is offline` | 心跳（500ms）到不了控制面：控制端口通不通？认证？节点 `--sc` 指对了吗？ |
| `writes … must go to its leader` | 打错了节点：用 `cluster leader --topic T --partition N` 拿 leader |
| `apply` 报未知函数/类型错误 | 表达式引用的函数集没部署到该节点，或集合更新后未 re-apply |
| `key/value of N bytes exceeds the … per-field limit` | 单条记录超 4 MiB。切分记录是应用语义，平台不代劳；请拆成多条（或改用算子链） |
| `batch exceeds the … batch budget` | 一个批帧超 16 MiB。用 `produce` 时不该出现（它自己按 4 MiB 分批）；出现即有人绕过了客户端内核直接构建帧 |
| `opened topic[N] (log end …, M segment(s))` 反复出现 | 这是 P16 的日志句柄诊断（stderr）。每个分区每个进程**只应出现一次**；反复出现说明该进程的缓存没命中（`MOONFLUX_LOG_CACHE` 被设成 0 或很小，或有人绕过了 `open_partition_log`） |
| 大批量生产/复制变慢 | 先看段大小与索引密度：读取按锚点定位，索引很稀会退化成整段扫描（`MOONFLUX_INDEX_EVERY`）。日志句柄默认已进程级复用（P16）；若 `opened` 行在刷屏，说明缓存没生效 |
| 门禁/脚本行为怪异 | 检查 `MOONFLUX_EXE` 指向的二进制是不是刚构建的；以及 shell 是否把含空格的 flags 变量当**一个**参数（zsh 不做词切分） |

**日志纪律**：服务端日志每行都有意义——认证模式与 TLS 在启动时明示；失败只报**状态迁移**（首次失败/恢复），不刷屏；凭据永不入日志。

## 11. 可复现脚本索引

| 想验证什么 | 跑什么 |
| :--- | :--- |
| 一切（46 步） | `scripts/gates.sh`（`fast` 跳过 E2E） |
| SDF 示例集的 8 个应用案例 | `scripts/e2e-p29-examples.sh`；逐案例说明见 `examples/sdf/*/README.md`，对照与缺口见 `docs/sdf-examples-port.md` |
| 图形化（Studio）对标探索与提案 | `docs/sdf-studio-exploration.md`（**未实现**：三阶段提案，含门禁形态） |
| CI：随推送的 fast（Linux，12 步） | GitHub Actions（[`.github/workflows/ci.yml`](../.github/workflows/ci.yml)）；本地等价物 `scripts/gates.sh fast`；日志 `gh run view --log-failed`。**日志可能被截断**（门禁输出混着数百条 moon warning，本仓实测 `--log-failed` 读不到末尾的汇总）：要全量就用原始日志 `gh api --allow-escape-sequences repos/dimon-83/moonflux/actions/jobs/<job-id>/logs`（job-id 由 `gh api repos/dimon-83/moonflux/actions/runs/<run-id>/jobs --jq '.jobs[] \| select(.name=="fast") \| .id'` 取） |
| CI：手动的 full（macOS，46 步 E2E） | `gh workflow run ci`（或网页 Actions → ci → Run workflow）；本地等价物 `scripts/gates.sh`。**full 有独立并发组**：手动跑全量期间推送不会把它取消（推送只取消同分支的前一次 `fast`） |
| 端到端管道 / 热重载 | `scripts/e2e-p0.sh` · `e2e-p1-rules.sh` |
| 集群/复制/选主/元数据 | `scripts/e2e-p3-*.sh` |
| 多分区复制与隔离 | `scripts/e2e-p7-partitions.sh` |
| 存储分段/索引/retention | `scripts/e2e-p8-storage.sh` |
| 键语义与键控压实 | `scripts/e2e-p14-compaction.sh` |
| 大载荷（分批生产 / 有界窗口 / 有界复制 / 超限拒绝） | `scripts/e2e-p15-bulk.sh` |
| 日志句柄复用（一次打开 / 淘汰安全 / 变更一致 / 复制不误判） | `scripts/e2e-p16-logcache.sh` |
| 基准（吞吐/延迟报告；门禁只断言结构） | `scripts/e2e-p17-bench.sh`；日常跑 `cli.exe benchmark produce\|consume\|latency` |
| 连接器：file/stdin/http | `scripts/e2e-p1-connectors.sh` |
| MQTT 订阅源 / 发布汇（含最小测试 broker） | `scripts/e2e-p19-mqtt.sh` · `scripts/mqtt_test_broker.py` |
| Kafka 消费源 / 生产汇（含最小测试 broker） | `scripts/e2e-p20-kafka.sh` · `scripts/kafka_test_broker.py` |
| 消费组 | `scripts/e2e-p9-groups.sh` |
| 安全面 | `scripts/e2e-p12-security.sh` |
| 控制面并发与停摆 | `scripts/e2e-p13-control-plane.sh` |
| 单机 `serve` 自任协调者的消费组 | `scripts/e2e-p22-serve-groups.sh` |
| 命令面尾巴（`partition list` / `cluster spu list` / `profile`） | `scripts/e2e-p23-cli.sh` |
| 无重启轮转（TLS 上下文与凭据表 mtime 热重载） | `scripts/e2e-p24-rotation.sh` |
| 批压缩（DEFLATE 双向外部锚定 + Kafka gzip） | `scripts/e2e-p25-compression.sh` |
| ABI v2 标量调用（沙箱标量与 mbel 逐字节对拍） | `scripts/e2e-p26-scalar.sh` |
| 协议/算子对拍 | `scripts/crosscheck-protocol.sh` · `crosscheck-operators.sh` |
| §9 实战示例覆盖的语义 | §9.1 函数集与发布期拦截：`scripts/e2e-p6-functions.sh`；§9.2 算子失败语义：`crosscheck-operators.sh`；§9.3 消费组：`scripts/e2e-p9-groups.sh`；§9.4 容错：`scripts/e2e-p3-failover.sh` · `e2e-p7-partitions.sh`；§9.5 安全：`scripts/e2e-p12-security.sh` |

## 维护规则

- CLI 面变化（新子命令/新 flag/新环境变量）**必须**同步本文 §2–§8；表达式/函数集的语言边界（§9 开头的三条）按 mbel 版本更新，若上游修掉 parity wart 也在此注明 与 [`cli-roadmap.md`](cli-roadmap.md)；新数据文件（`*.json` 落盘物）同步 §"存储运维"。
- 排查表按"真实踩到"增补（一行一个症状 + 一个原因），不预设。
- 行为语义的验证状态不在本文维护——见 [`compatibility-matrix.md`](compatibility-matrix.md) 与 [`feature-matrix.md`](feature-matrix.md)。
