# P29 · SDF 示例移植与 Studio 对标（overview）

**Objective**: 把 InfinyOn `stateful-dataflow-examples` 的示例移植为可运行的 moonflux 应用案例（含门禁），并对 SDF Studio 的图形化方案做对标探索与分期提案。

**Why now**: 用户要求"用其中的例子构建 moonflux 的应用案例，并探索 SDF Studio 图形化方案"。示例集是对标系统的表达能力清单；把它逐条落到 moonflux 上，是对"同等能力与地位"这一主张最直接的压力测试——能落的落，不能落的写清楚为什么。

**Scope**:
- T103 案例集：`examples/sdf/*`（8 例，冻结 spec + 夹具 + expected + README）
- T104 两个新 guest 算子（filter 1→0、flatmap 1→N）+ 门禁 `scripts/e2e-p29-examples.sh`（8 腿）
- T105 SDF Studio 对标探索文档（概念对照 / 分期提案 / 非目标）

**Non-goals**（见 `docs/sdf-examples-port.md` §5）：不引入服务内键控状态、窗口/水位、SQL 引擎、Rust SmartModule 工具链。

**Evidence**: `scripts/e2e-p29-examples.sh`（8 腿绿）+ `scripts/build-operators.sh`（6 个算子模块 + ABI 探针）。
