# 部署指南：SDF 例子的 native 与 Docker 部署

> **这份文档说的是"怎么把 examples/sdf 当成一个部署物跑起来"**，不是"怎么跑门禁"。
> 门禁证明的是逐字节语义（[`scripts/e2e-p29-examples.sh`](../scripts/e2e-p29-examples.sh)）；
> 部署证明的是**能启起来、看得到、读得了、停得干净**（[`scripts/e2e-p41-deploy.sh`](../scripts/e2e-p41-deploy.sh)）。
> 决策依据：README 决策 86。

## 1. 形状：一个用例 = 一次部署，broker 是**运行登记处**

例子目录**不是一个"单集群多任务"目录**，这是有数据的：

| 冲突 | 出现在 | 性质 |
| :--- | :--- | :--- |
| `sentence` | 15-word-counter、24-openai-callout | **跨用例** |
| `cars` | 19-car-processing、22-http-callout | **跨用例** |
| `business-events` | 17-bank-processing 的 2 个 stage | 用例内（同一份流的两个消费者） |
| `sdf-06-licenses` | 06-merge-two-sources 的 2 个 stage | 用例内（fan-in） |
| `cars` | 19-car-processing 的 6 个 stage | 用例内（同一份数据的多个分析） |

P37 的规则是"**一个数据主题属于恰好一个任务**"（读取端只按主题选链），所以把这些
扁平化到一个集群里会被**按名拒绝**——而那是**正确**的拒绝。

于是部署的形状是：

```
_deploy/
├── broker/                 # 运行登记处（serve + /metrics），不存放任何用例的数据
├── cases/<case>/           # 每个用例**自己的主题空间**（topics/、topology.json、日志）
├── logs/<case>.out|.err    # 捕获的 stdout / stderr
├── logs/<case>.apply|.fns  # apply 与函数集部署的输出（失败时第一现场）
├── run/pids                # 记录的进程表（stop 用）
└── catalog.tsv             # 用例、模式、spec 文件名、理由（**没有静默跳过**）
```

运行通过 `--control 127.0.0.1:<port>` 向登记处报到（P37-2），**但记录仍写在自己的数据目录里**
（`<task>.run-log` 在 `cases/<case>/` 下）。这就是为什么一个 broker 能同时看见整个部署，
而用例之间又不会互相污染主题空间。

## 2. 用例的三种模式（catalog.tsv 逐行写明）

| 模式 | 含义 | 现在有哪些 |
| :--- | :--- | :--- |
| `run` | 单 spec、源是 file/stdin、且有**单一** `expected.txt` → 跑 + **逐字节验证** | 5 个（01/02/03/04/13） |
| `run-unverified` | 单 spec、源是 file/stdin，但**没有单一 golden** → 跑，但**如实说明为什么不算验证过** | 3 个（08 有 4 份视图、20/21 各有流与状态两份） |
| `deploy-only` | 多 stage（stage 顺序**按用例文档**，不由脚本猜）／需要外部系统（http/mqtt/kafka）／目录里没有 spec | 18 个 |

部署脚本**从不**代替你选择"用哪份 expected 去比"——那是在替用例编造含义。

## 3. 命令

```bash
# 起：建部署根、起登记处、逐个 apply + run（可自动跑的用例），等它们跑完
scripts/deploy-sdf.sh start

# 看：登记处的运行表 + catalog 的逐行结论（verified / ran, not verified / deploy-only + 理由）
scripts/deploy-sdf.sh status

# 验：可验证用例与其 expected.txt 逐字节对拍（与 p29 门禁同一套 golden）
scripts/deploy-sdf.sh verify

# 读：某个用例的 stderr（诊断）、stdout（汇的数据）、以及它的 run-log 主题
scripts/deploy-sdf.sh logs 13-parse-sentence

# 列：catalog 原始内容（制表符分隔，`cut -f1` 可用）
scripts/deploy-sdf.sh list

# 停：杀掉记录的进程与登记处；**保留部署根**，日志仍然可读
scripts/deploy-sdf.sh stop
```

环境变量：`MOONFLUX_DEPLOY_DIR`（默认 `./_deploy`）、`MOONFLUX_EXE`（默认 debug 构建）、
`MOONFLUX_DEPLOY_PORT` / `MOONFLUX_DEPLOY_METRICS_PORT`（默认 19801/19802）。

**发布构建**同样是这条路：`moon build --target native --release` 之后
`MOONFLUX_EXE=_build/native/release/build/apps/cli/cli.exe scripts/deploy-sdf.sh start` ✓
（算子模块路径在 spec 里是**相对于仓库根**的，所以部署根不能搬离仓库——这条边界见 §5。）

## 4. 前置条件与失败的第一现场

- `scripts/build-operators.sh` 必须先跑过：spec 引用的 wasm 算子要存在，否则 `start` 会在
  **preflight** 阶段一次性报出所有缺失模块（而不是逐个用例在 apply 时慢慢暴露）。
- 函数集：用例有 `fns.json` 就先 `function-set create` **进该用例自己的数据目录**（01 是唯一一个）。
- 失败的第一现场在 `logs/<case>.apply` 与 `logs/<case>.fns`；`logs/<case>.err` 是运行期诊断。

## 5. 如实边界

1. **部署根不能搬离仓库**：spec 里的 wasm 路径相对仓库根（镜像里也保留同一布局，见 Docker 一节）。
2. **多 stage 用例不会被自动跑**：它们的顺序写在各自 README 里，脚本不猜（猜了就是把
   用例的语义偷偷改掉）。要跑它们请按 README 的顺序手动 `pipeline run`，或把它们自己的
   顺序文档补齐后按 `catalog.tsv` 的 `spec` 列逐个跑。
3. **没有单一 golden 的用例不算"验证过"**：它跑了、输出留在 `logs/`，但 `verify` 不把它
   算进通过数——这正是 `run-unverified` 存在的理由。
4. **`stop` 是信号，不是编排器**：它按记录的 pid 停进程（TERM → 1s → KILL）。真正的
   start/stop/status 编排（runner）是 P37-5 的事，还没做；本脚本不假装有。
5. **Docker 路径**：见 §6——本机 docker 守护进程不可用，所以 Docker 只能在 CI 的 ubuntu
   runner 上真构建真冒烟，本地只做静态校验（这条边界同样写在决策里）。

## 6. Docker 部署（决策 87）

**镜像保留仓库相对布局**：目录里的 spec 用仓库相对路径引用算子 wasm（77 处，**debug** 路径），
所以 `/opt/moonflux` 就是仓库根，运行阶段带的正是那些 debug 模块。改写 spec 去迁就镜像，
就是让镜像来管目录——不做。

```bash
# 起 broker（+ /metrics 与 /healthz）与控制台
docker compose -f deploy/docker/compose.yaml up -d broker console
# 控制台：http://localhost:8080/?broker=19801

# 一用例一容器：CASE 是 examples/sdf 下的目录名
docker compose -f deploy/docker/compose.yaml --profile case \
  run --rm -e CASE=13-parse-sentence case

# 集群形状（控制面 + 两个数据节点）代替单个 broker
docker compose -f deploy/docker/compose.yaml --profile cluster up -d

# 只要镜像
docker build -f deploy/docker/Dockerfile -t moonflux:local .
docker run --rm moonflux:local doctor
```

**实测（本机 arm64，本地守护进程起来后真跑，随后 CI amd64 复跑）**：镜像 70.5 MB；
`doctor` 在镜像内报出落盘原语与算子宿主；目录 spec 在镜像内编出视图模型；broker 容器答
`/healthz` 且 `/metrics` 无标签；**`13-parse-sentence` 在容器里跑出与其 `expected.txt`
逐字节一致**。构建侧需要：C 工具链且**必须是 clang**（native-stub 按名解析 clang）、
wasmtime C API **按构建架构**选包并在装完后 `ldconfig`、基础镜像名是 `moon.mod`（不是
`.json`）。另外：**`scripts/build-operators.sh` 现在能在干净树里构建了**——此前模块级
`--target wasm` 在冷树产出 0 个 `.wasm`，而 `--output-wat` 只产 `.wat`；是镜像构建第一次
从纯净树构建才暴露出来的。

**怎么被证明的（以及为什么不在本机）**：本机只有 docker **客户端、没有守护进程**，
所以容器路径由 **CI 的 `docker` 作业**证明（`MOONFLUX_REQUIRE_DOCKER=1`）：从干净检出
构建镜像 → `doctor` 断言平台事实 → 目录里的 spec 编出视图模型 → broker 容器答 `/healthz`
与无标签 metrics → **在容器里跑一个真实用例并与 `expected.txt` 逐字节对拍**。
`scripts/e2e-p42-docker.sh` 在 `gates.sh` 里只做静态（并在输出里**明确说动态那半没跑**）；
`REQUIRE_DOCKER=1` 时没有守护进程就是**失败**——所以"没有守护进程"不会悄悄放过一个容器门禁。
