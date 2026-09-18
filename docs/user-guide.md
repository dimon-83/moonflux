# moonflux 实用文档（操作手册）

> **定位**：面向使用者与运维——从源码构建到跑通第一个管道，到多节点集群、安全配置与故障排查。**规约依据**：AGENTS.md §10（引用与证据规范）；**边界声明**：本文只讲"怎么用"；架构原理见 [`architecture.md`](architecture.md)，能力与状态的完整清单见 [`feature-matrix.md`](feature-matrix.md)。所有示例在 macOS/Linux + OpenSSL 环境可复现。
>
> **日期**：2026-09-17 · 对应版本：P0–P13

## 1. 构建与自检

```bash
cd ~/workspace/moonflux
moon build --target native          # 产物：_build/native/debug/build/apps/cli/cli.exe
moon test --target native           # 203 项
moon test --target wasm-gc          # 148 项（内核全后端）
scripts/gates.sh                    # 全量门禁（31 步）；scripts/gates.sh fast 跳过 E2E
```

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

**spec 形态**（`core/spec::parse_spec` 是唯一权威）：

| 字段 | 取值 |
| :--- | :--- |
| `spec.source.type` | `file`（配 `path`）· `http`（配 `url`，http/1.1）· `stdin` |
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
- 分区是复制的单元：3 分区 RF=2 时，杀掉一个节点只停它持有的分区，其余分区照常推进；新 leader 由最小滞后副本自我提升（提名随心跳下发）。
- 数据节点离开控制面也能跑（自持已应用管道的 partition 0），日志会写明这是退化自放置。

## 4. 消费组（至少一次）

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
- 消费组有提交的分区参与 retention 下界（最慢消费者挡住删除）；从未提交的组不算"落后"。

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
cli.exe function-set create --file fns.json --remote 127.0.0.1:19451
cli.exe function-set list   --remote 127.0.0.1:19451
```

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
```

| 环境变量 | 作用 | 缺省 |
| :--- | :--- | :--- |
| `MOONFLUX_ROLL_BYTES` / `MOONFLUX_ROLL_MS` | 段滚动阈值（字节 / 时长） | 关闭（单段） |
| `MOONFLUX_RETAIN_BYTES` / `MOONFLUX_RETAIN_MS` | retention 策略 | 关闭 |
| `MOONFLUX_INDEX_EVERY` | 索引锚点密度 | 内置值 |

- 段边界永远是帧边界；只有最后一段可能带撕裂尾（崩溃恢复截断并报告）。
- **retention 只删整段、只删 floor 以下**：floor = `min(leader 已提交前缀, 最慢消费组的提交偏移)`；删完后更老的读得到 `OffsetOutOfRange`（"没了"≠"空"）。每次删除打印段 base/记录数/字节数与新可读起点。
- `.idx` 损坏不用修：任何疑点自动回退全扫，结果与有索引逐字节一致。

## 8. Web 编辑器

```bash
cli.exe serve --data-dir d --listen 127.0.0.1:19420 --ws
# 浏览器打开 http://127.0.0.1:<port>/ —— 与 CLI 同端口、同一协议（WS 升级）
```

拖拽 Source/Transform/Sink → 部署（`CMD_APPLY_PIPELINE`）→ 在编辑器内消费。编辑器是 spec 的渲染器：它产出的就是 `PipelineSpec`，CLI 与浏览器看到同一个真相。

## 9. 故障排查

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
| 门禁/脚本行为怪异 | 检查 `MOONFLUX_EXE` 指向的二进制是不是刚构建的；以及 shell 是否把含空格的 flags 变量当**一个**参数（zsh 不做词切分） |

**日志纪律**：服务端日志每行都有意义——认证模式与 TLS 在启动时明示；失败只报**状态迁移**（首次失败/恢复），不刷屏；凭据永不入日志。

## 10. 可复现脚本索引

| 想验证什么 | 跑什么 |
| :--- | :--- |
| 一切（31 步） | `scripts/gates.sh`（`fast` 跳过 E2E） |
| 端到端管道 / 热重载 | `scripts/e2e-p0.sh` · `e2e-p1-rules.sh` |
| 集群/复制/选主/元数据 | `scripts/e2e-p3-*.sh` |
| 多分区复制与隔离 | `scripts/e2e-p7-partitions.sh` |
| 存储分段/索引/retention | `scripts/e2e-p8-storage.sh` |
| 消费组 | `scripts/e2e-p9-groups.sh` |
| 安全面 | `scripts/e2e-p12-security.sh` |
| 控制面并发与停摆 | `scripts/e2e-p13-control-plane.sh` |
| 协议/算子对拍 | `scripts/crosscheck-protocol.sh` · `crosscheck-operators.sh` |

## 维护规则

- CLI 面变化（新子命令/新 flag/新环境变量）**必须**同步本文 §2–§8 与 [`cli-roadmap.md`](cli-roadmap.md)；新数据文件（`*.json` 落盘物）同步 §"存储运维"。
- 排查表按"真实踩到"增补（一行一个症状 + 一个原因），不预设。
- 行为语义的验证状态不在本文维护——见 [`compatibility-matrix.md`](compatibility-matrix.md) 与 [`feature-matrix.md`](feature-matrix.md)。
