# SDF 示例集的 moonflux 应用案例（对照与缺口）

> **定位**：把 [`stateful-dataflow-examples`](https://github.com/infinyon/stateful-dataflow-examples)（InfinyOn 官方的 Stateful Dataflows 示例集）里的示例，逐个映射为**可运行、可门禁验真**的 moonflux 应用案例（[`examples/sdf/`](../examples/sdf/)），并如实列出无法映射的部分。**规约依据**：AGENTS.md §7（对标参考系统规则——语义借鉴必须留痕、不得把参考系统的默认假设无意识带入）与 §10（证据与状态规范）。**边界声明**：SDF 是**对标与互操作参照**，不是 moonflux 的上游或依赖；本文的每条结论都对应 `scripts/e2e-p29-examples.sh` 的一条腿，或明确标注为"缺口"。
>
> **日期**：2026-10-10

## 1. 来源盘点（先事实，后映射）

对示例集做了逐目录清点（32 个 `dataflow.yaml` + 5 个 `sdf-package.yaml`，共 37 个示例目录）。四条决定映射方式的事实：

| 事实 | 含义 |
| :--- | :--- |
| 全部 `transforms:` 里只出现 **4 个算子**：`map` / `filter` / `filter-map` / `flat-map` | 所谓 `merge`、`split`、`regex`、`sql`、`update-state` **都不是算子**：前两者是拓扑（多源/多汇），`regex` 是 `filter` + crates.io 的 regex crate，`sql` 是宿主函数，`update-state` 是 `states:` + `partition.*` |
| 所有 `sources:`/`sinks:` 都是 `- type: topic` | SDF 数据流是"主题进、主题出"；外部数据靠 `fluvio produce` 或连接器落进主题 |
| 13 个目录需要**持久键控状态**（`states:` + `partition.assign-key` + `update-state`，部分带 tumbling window） | 这一族在 moonflux 里没有对应能力，只能如实标注为缺口（§4） |
| `config.converter: json\|raw` 决定载荷是否按生成的结构体编解码 | moonflux 的载荷是**不透明字节/字符串**，语义上是 SDF 的 `raw`；结构由变换自己决定（JSON 进 JSON 出只是文本） |

## 2. 逐案例对照

十三个案例都在 [`examples/sdf/`](../examples/sdf/)，每例含 spec + 夹具 + `expected*.txt` + 说明；01–08 与 12–13 由 `scripts/e2e-p29-examples.sh`（12 腿）验真，09–11 由 `scripts/e2e-p30-connector-examples.sh`（6 腿，对端是仓库自带的测试 broker/HTTP 服务）验真。

| # | 案例 | SDF 出处 | moonflux 形状 | 门禁腿 |
| :--- | :--- | :--- | :--- | :--- |
| 1 | [`01-map-mask-ssn`](../examples/sdf/01-map-mask-ssn/) | `primitives/map`、`dataflows/mask-user-pii`、`packages/mask-ssn` | **函数集资产**（`fns.json` 的 `pii.mask_ssn`）+ `expr` 规则按名引用；SDF 的 `packages/*` 在这里的对应物是函数集 | 1 |
| 2 | [`02-filter-questions`](../examples/sdf/02-filter-questions/) | `primitives/filter` | 沙箱算子 `operator-filter`（`{"contains":"?"}`）——1→0 | 2 |
| 3 | [`03-filter-map-uppercase`](../examples/sdf/03-filter-map-uppercase/) | `primitives/filter-map` | 链：wasm `operator-filter`（`{"min_len":11}`）→ mbel `upper(value)` | 3 |
| 4 | [`04-flat-map-words`](../examples/sdf/04-flat-map-words/) | `primitives/flat-map`、`dataflows/split-sentence` | 沙箱算子 `operator-flatmap`（`{"separator":" "}`）——1→N | 4 |
| 5 | [`05-split-two-streams`](../examples/sdf/05-split-two-streams/) | `primitives/split/filter` | **两条入口 spec**（各一个过滤分支、各自主题），断言两个分支不相交 | 5 |
| 6 | [`06-merge-two-sources`](../examples/sdf/06-merge-two-sources/) | `primitives/merge` | **两条入口 spec 写同一个主题**；主题即合并后的流（偏移 0..3 连续） | 6 |
| 7 | [`07-key-value-keys`](../examples/sdf/07-key-value-keys/) | `primitives/key-value/{input,output,chained}` | key 是**日志的一列**：`produce --key-separator` 打戳、`consume` 第 3 列可见、跨存储存活 | 7 |
| 15 | [`15-word-counter`](../examples/sdf/15-word-counter/) | `dataflows/word-counter` | `wordkeys`（设键）+ `counter`（ABI v3 状态）；字节级冻结首跑/续跑/状态主题三份 | 16 / 17 |
| 8 | [`08-state-is-the-log`](../examples/sdf/08-state-is-the-log/) | `primitives/update-state`、`dataflows/word-counter` | ① 同一主题两个视角（`consume --remote` 走已应用拓扑=服务视图；`consume --data-dir`=原始日志视图）；② 键控压实作为"每键最新"的物化，偏移不变 | 8a / 8b |
| 9 | [`09-http-source`](../examples/sdf/09-http-source/) | `dataflows/car-processing`、`dataflows/ny-transit`（入湖段） | **spec 内的 HTTP 源**：一次性 GET（`spec.json`）与**轮询**（`spec-poll.json`，`interval_ms`）两种形态 → 沙箱过滤 → 主题；日志保留原始抓取 | 1, 7 |
| 10 | [`10-mqtt-transit`](../examples/sdf/10-mqtt-transit/) | `dataflows/helsinki-transit`（入湖段） | **spec 内的 MQTT 订阅源**（流式，不停机）→ 主题；线上形状由仓库自带的 MQTT 测试 broker 断言 | 2–3 |
| 11 | [`11-kafka-bridge`](../examples/sdf/11-kafka-bridge/) | **无直接对应物**（示例集全是 topic→topic，连接器在数据流之外） | **kafka 源 → 过滤 → kafka 汇**、两个 broker；断言读的是对端自己的 received 文件 | 4–6 |
| 12 | [`12-custom-serialization`](../examples/sdf/12-custom-serialization/) | `primitives/custom-serialization/struct/{deserialize,serialize}` | 载荷不透明 + 表达式做字段读写：`get(fromJSON(value), k)` 读、`toJSON(fromPairs([...]))` 写、`toPairs/fromPairs` 恒等往返 | 9–11 |
| 14 | [`14-regex-genz`](../examples/sdf/14-regex-genz/) | `primitives/regex`（`filter` + regex crate；该例自述主题是 crates.io 依赖管理，不抄） | **spec 级 `{"type":"regex","pattern":…}` 过滤器**（可选 `invert`），内核自带纯 MoonBit 引擎；不支持的构造在 apply 期按名拒绝 | 13–15 |
| 13 | [`13-parse-sentence`](../examples/sdf/13-parse-sentence/) | `packages/parse-sentence`（`sentence-to-words` + `word-length`） | 沙箱 flat-map 做分词 + 规则 `string(len(value))` 做长度（规则必须返回字符串，故显式 stringify） | 12 |

**为此新增的两个 guest 算子**（SDF 的 `filter`/`flat-map` 在 moonflux 里必须落在沙箱，因为 mbel 表达式**必须返回字符串**，无法表达"丢弃"）：

- `apps/operator-filter`：`{"min_len": N}` / `{"contains": "s"}`，两键可并用；未知键在 `mf_op_init` 拒绝，小数 `min_len` 也拒绝（不静默取整）。
- `apps/operator-flatmap`：`{"separator": "s"}`，空分隔符拒绝；每个 token 继承源记录的 key/timestamp/headers。
- 两者都由 `scripts/build-operators.sh` 构建、由 `tools/probe_operator_exports.py` 探针（无导入段 + 成对导出规则）把守。

## 3. 语义映射表

| SDF 概念 | moonflux 对应物 | 是否等价 |
| :--- | :--- | :--- |
| `topics:` + 主题内数据 | topic 分区日志（`core/log`） | ✅ 同一层概念 |
| `services:` 的 `sources: topic` → `sinks: topic` | **已应用拓扑**（`pipeline apply` 写 `topology.json`，服务端在取数路径上应用）+ 入口式 pipeline（外部源 → 主题 → 汇） | ⚠️ 形状不同：SDF 服务是"主题→主题"的常驻程序；moonflux 的 spec 是**入口式**（外部源→主题→汇），消费侧变换由节点上唯一的一份已应用拓扑提供 |
| `transforms:` 挂在 service / source / sink / partition 四处 | 变换链挂在 spec 上（每个 spec 一条链，整份 spec 与一个主题绑定） | ⚠️ moonflux 是**每节点一份拓扑**，不是每服务/每汇一份；`split` 的"一服务多汇"没有直接对应物 |
| `operator: map/filter/filter-map/flat-map`（Rust SmartModule） | `{"type":"wasm"}`（ABI v1 批算子，1→N/1→0 都可）、`{"type":"scalar"}`（ABI v2 标量，逐条）、`{"type":"expr"}`（mbel 规则，**必须返回字符串**） | ⚠️ 能力覆盖 1→1/1→0/1→N；但**规则不能丢弃记录**，所以 filter 类必须走沙箱 |
| `packages/*`（`sdf build` + Hub 分发 + `uses:`） | **函数集资产**（`function-set create`，JSON 文档 + 单调 revision + apply 时按名绑定）与算子模块（wasm 制品） | ⚠️ 形态相近，分发不同：moonflux 是逐节点/控制面持有，SDF 走 Hub 包市 |
| `config.converter: json`（生成类型 + 序列化） | 无对应物（载荷不透明） | ❌ 缺口（schema 类型语言 + codegen） |
| `config.consumer.default_starting_offset` | `consume --from N`、Kafka 源 URL 的 `from=earliest\|latest`、消费组提交偏移 | ✅ 概念对应 |
| key/value 调用约定（`Option<String>` 入参、`(Option<String>, U)` 出参、链上 key 存活） | key 是日志列：produce 打戳、变换与存储保留 | ⚠️ 无"变换产生新 key"的路径 |
| `states:` + `partition.assign-key` + `update-state`（arrow-row / scalar 双 API） | **无对应物**；最接近的是键控压实物化"每键最新" | ❌ 缺口（§4） |
| `window.tumbling` + `watermark` + `flush` | **无对应物** | ❌ 缺口 |
| `sql(...)` 宿主函数与 REPL | **无对应物** | ❌ 缺口（且不属平台职责，见 §5） |
| `sdf run --ui` / `sdf deploy --ui`（Studio） | `serve --ws` + `web/editor/`（spec 渲染器）+ CLI 观测命令 | ⚠️ 见 [`sdf-studio-exploration.md`](sdf-studio-exploration.md) |

## 4. 缺口清单（不假装能跑的部分）

> **处置方案见 [`sdf-gap-closure-plan.md`](sdf-gap-closure-plan.md)**：九条逐条判定"追平 / 变通 / 不做"、设计要点、门禁形态与依赖顺序。本节只声明缺口本身。


1. **服务内持久键控状态**。**已追平（2026-10-11，T114，决策 60/61）**：ABI v3（状态以数据进出、guest 仍无导入）+ `spec.state.topic` + 宿主视图（启动重放、批后写回）已落地，`scripts/e2e-p31-state.sh` **11 腿**（跨进程续算、压实后仍正确、两份全新 dir 逐字节一致、无键拒绝且零写入、上限**写前**拒绝、v3 成对 + 头部、v1 回归、窗口隔离、窗口只随数据推进、"复制状态主题即可复现视图"）。**架构承诺与 SDF 不同，这点说清楚**：状态不是服务内的对象，而是**一条键控主题**——于是复制、压实、floor、恢复全部复用既有四件套，"每键最新"就是压实的语义。**仍缺**：跨节点状态迁移/再均衡（单机状态已具备）。
   原来的叙述保留在下面，读者可以看到它曾经是什么：~~moonflux 的算子是无状态纯函数（guest 无导入、无时钟、无随机源——结构性事实而非约定），宿主也不持有 per-key 状态。影响：`update-state`、`bank-processing` 的余额、`car-processing` 的按色计数、`word-counter`/`word-probe`/`helsinki-transit`/`ny-transit`/`openai-callout` 全部无法等价移植。~~
2. **窗口与水位**。**tumbling 已追平（2026-10-11，T114，决策 61）**，而且不需要 watermark：**窗口就是键的形状**——`apps/operator-tumble` 把 key 改写成 `key@窗口起点`，于是窗口复用键控状态（同一词在两个窗口是两个状态项，各自从 1 起算；门禁腿 9）。**如实边界**：① **没有 idle 触发器**（窗口只因更晚窗口的记录而更换——SDF 自己 README 承认的缺口在我们这里同样存在，只是更彻底：没有时钟就没有 idle 这回事）；② **窗口不自动过期**（旧窗口的状态项留到压实/retention）；③ **hopping / watermark 触发 flush 未立项**——那需要"水位推进才产出"，与"算子不读时钟"的红线冲突，要做先得定义事件时间水位的来源。
**正则（`primitives/regex`）——已追平（2026-10-10，T111，决策 59）**：内核自带 `core/regex`（纯计算、四后端），spec 面 `{"type":"regex","pattern":P}`（可选 `invert`）；子集明确，`\b`/反向引用/环视/懒惰量词/Unicode 类等在 apply 期按名拒绝。SDF 那个示例真正演示的 crates.io 依赖管理**不抄**（AGENTS §1.1）。

3. **SQL 引擎**。
   *（正则一项见下）*
`sql()` 是 SDF 宿主函数（表=状态对象、`_key` 隐式列、支持 `FULL OUTER JOIN`/`GROUP BY`/`ORDER BY`）。moonflux 没有查询引擎，也不打算把 SQL 塞进数据路径（见 §5）。
4. **schema 类型语言与 codegen**。`types:` 的对象/列表/枚举（`oneOf`）、字段重命名、per-schema converter、以及"hyphenated 字段 → snake_case"的隐式转换，均无对应物。**部分收口（2026-10-10，T108）**：字段级读写已可直接用 `get(fromJSON(value), k)` / `toJSON(fromPairs([...]))`（案例 12 三腿，含恒等往返）——缺的只是**编译期类型与生成代码**，而这是有意不做的方向（载荷保持不透明，畸形记录在运行期逐条 fail-closed）。
5. **Rust/SmartModule 工具链**。`sdfg@0.13` + `#[sdf(fn_name=...)]` + `wasm32-wasip2` + crates.io 依赖解析 + Hub 分发。moonflux 的 guest 是 MoonBit 写的（`apps/operator-sdk`），不提供 Rust 编译链，也不从 crates.io 取依赖（AGENTS §1.1 依赖合规）。**作者面已补（2026-10-10，T112，决策 58）**：能力等价物早在（SDK + ABI + 探针 + 双后端对拍 + `build-operators.sh`），现在再加 [算子作者指南](operator-authoring-guide.md) 与稳定 C ABI 头 `apps/operator-sdk/include/moonflux_operator.h`（每次构建校验头部与实现不漂移）。**任何能产出无导入 wasm 的语言都可以写 guest**；仓库仍不提供 Rust 工具链、不引入 wasip2/组件模型。
6. **`split` 拓扑**。一服务多汇（sink-scoped transforms）在 moonflux 里没有对应物：一份 spec 一个汇、一个主题；一节点一份已应用拓扑。
7. **pipeline 不能以主题为源**。moonflux 的 spec 源只有 file/http/stdin/mqtt/kafka；"主题→主题"的服务形态要靠服务端的已应用拓扑（消费侧变换），而不是再写一条 pipeline。这是有意的分工，但对 SDF 的读者是首要的心智落差。
8. ~~**函数集没有本地创建路径**（实测，CLI 缺口）~~ **已收口（2026-10-10，T107，决策 56）**：`function-set create/get/list/delete` 现在都接受 `--data-dir`，本地路径**复用节点侧同一份 handler**，因此本地与 serve 的应答逐字节同源；同时给 `--remote` 与 `--data-dir` 互斥按名拒绝（那是两句不同的话）。案例 1 的步骤已从"先起一个 serve 装资产"简化为直接落到运行用的 data dir。
9. **InfinyOn Cloud / 连接器仓库 / 外部数据源**（`demo-data.infinyon.com`、`mqtt.hsl.fi`、`hnrss.org`、`api.openai.com`、Hub 上的 `http-source@0.4.3` 等）。这些是外部依赖，不在移植范围；moonflux 侧的 HTTP/MQTT/Kafka 连接器是自建实现。

   **部分收口（2026-10-10）**：HTTP/MQTT/Kafka 三类外部数据案例已落地（上方案例 9–11，7 腿全绿，全部使用仓库自带的测试对端，**不需要外网**）；**轮询式 HTTP 源也随之落地**（`interval_ms`，T109，决策 57：轮询期说 `Quiet` 永不说 `Exhausted`，每次重取各成一批）。仍缺一件：**逐记录 HTTP callout**（`http-callout`/`openai-callout`）——须先在"接受非确定性"与"记录-回放"之间选边，方案见 [`sdf-gap-closure-plan.md`](sdf-gap-closure-plan.md) §2 缺口 9。

## 5. 明确不做（与 §4 的区别）

- **不在数据路径里加状态或窗口**。状态算子会让"同输入同输出"的确定性承诺复杂化，并且需要新的持久化面（当前持久化的只有日志、元数据与组偏移）。若将来确需，应作为**显式立项**（含持久化格式、恢复语义、与压实/retention 的交互、门禁形态），而不是顺手加一个算子。
- **不引入 SQL 引擎**。查询是消费方的事；把 SQL 放进平台要重定义"谁拥有状态"（正是 SDF 用 `states:` + SQL 回答的问题），与本项目的"日志是唯一持久真相"相冲突。
- **不复制 Rust 工具链与 crates.io 依赖**（AGENTS §1.1 三项：结构/习惯/依赖合规）。
- **不把示例集当作规范**。示例是**互操作与表达能力**的参照；moonflux 的语义（至少一次、无 leader epoch、默认未提交读、无状态算子）不被 SDF 的默认假设改写（AGENTS §7）。

## 6. 证据

```bash
scripts/build-operators.sh     # 6 个 guest 模块（含新增的 filter/flat-map）+ ABI 探针
scripts/e2e-p29-examples.sh    # 8 条腿：8 个案例端到端、字节级对拍
```

门禁断言的是**结构与字节**：每个案例的 stdout（或 `consume` 的指定列）与其冻结的 `expected*.txt` 逐字节一致；案例 8b 另断言压实报告（恰好 1 段被封存、恰好 1 条被取代记录被丢弃）、地板之下的读是 `OffsetOutOfRange` 结构化拒绝、幸存记录保持原偏移。没有一条断言依赖耗时或机器负载（README 决策 41）。

## 维护规则

- 新增案例：先落 `examples/sdf/<NN-name>/`（spec + 夹具 + expected + README，注明 SDF 出处与差异），再在 `scripts/e2e-p29-examples.sh` 加一条腿，最后在本表登记——三者缺一不算完成（AGENTS §10）。
- 缺口清单只增不删：某项被补齐时改为"已达成（日期 + 证据）"，保留原文以便读者知道它曾经不存在。
- 语义映射若发生变化（例如未来支持了状态算子），必须同时更新本表与对应案例的 README，并记入 README「关键决策记录」。
