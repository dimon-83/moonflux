# SDF 示例集覆盖清单（权威）

> 本文件是"示例集全部条目是否做完"的**唯一权威答案**：参考仓库
> `stateful-dataflow-examples` 的每一个条目在这里有一行，状态只有两种——
> `ported`（有可运行案例 + 门禁腿）或 `non-goal`（明确不做，且**必须写出替代或理由**）。
> `scripts/audit-sdf-coverage.sh` 逐行核对本表：`ported` 行的案例目录必须存在、
> 必须能在 `scripts/e2e-p29-examples.sh` 里找到；`non-goal` 行必须写清理由或替代。
> **清单与代码不一致时门禁变红**，所以"做完了"这句话是可证伪的。

| 参考条目 | 类别 | 状态 | 我们的案例 | 门禁 / 说明 |
| :--- | :--- | :--- | :--- | :--- |
| `dataflows/word-counter` | dataflow | ported | examples/sdf/15-word-counter | p29 腿 16–17（**20 秒窗口 + 关闭时 flush top-3** = 参考的真实形状；另附计数半的续跑） |
| `dataflows/word-probe` | dataflow | ported | examples/sdf/16-word-probe | p29 腿 18–19（**主题接力**：句子主题 → 计数跟随者（写状态）→ 词主题 → 探测跟随者（读状态，零写入）） |
| `dataflows/bank-processing` | dataflow | ported | examples/sdf/17-bank-processing | p29 腿 20–22（**主题接力**：业务事件主题 → 余额跟随者；透支主题 → 透支跟随者；参考样本原样） |
| `dataflows/unreal-engine-analytics` | dataflow | ported | examples/sdf/18-unreal-engine-analytics | p29 腿 23–25（183 事件原样；标签映射；10 秒窗口） |
| `dataflows/car-processing` | dataflow | ported | examples/sdf/19-car-processing | p29 腿 26–29（超速/地点/颜色窗口/套牌；合成夹具） |
| `dataflows/helsinki-transit` | dataflow | ported | examples/sdf/20-helsinki-transit | p29 腿 30–31（清理 + 每车 5 秒平均速度） |
| `dataflows/ny-transit` | dataflow | ported | examples/sdf/21-ny-transit | p29 腿 32–33（每区 30 秒平均小费；合成夹具） |
| `dataflows/http-callout` | dataflow | ported | examples/sdf/22-http-callout | p29 腿 34–35 + p32 9 腿（宿主侧 callout，mode 必填） |
| `dataflows/openai-callout` | dataflow | ported | examples/sdf/24-openai-callout | p29 腿 38–39（POST + 模型解析 + 每模型计数；凭据不入磁带） |
| `dataflows/hackernews-notify` | dataflow | ported | examples/sdf/25-hackernews-notify | p29 腿 40–41（**主题接力**：请求主题 → 订阅跟随者；文章主题 → 通知跟随者；订阅表去重 + 逐订阅者通知） |
| `dataflows/mask-user-pii` | dataflow | ported | examples/sdf/01-map-mask-ssn | p29 腿 1（mbel 规则遮蔽 PII 字段） |
| `dataflows/split-sentence` | dataflow | ported | examples/sdf/04-flat-map-words | p29 腿 4（1→N 拆句） |
| `primitives/map` | primitive | ported | examples/sdf/01-map-mask-ssn | p29 腿 1 |
| `primitives/filter` | primitive | ported | examples/sdf/02-filter-questions | p29 腿 2（1→0 需要沙箱：规则必须返回字符串） |
| `primitives/filter-map` | primitive | ported | examples/sdf/03-filter-map-uppercase | p29 腿 3 |
| `primitives/flat-map` | primitive | ported | examples/sdf/04-flat-map-words | p29 腿 4 |
| `primitives/split` | primitive | ported | examples/sdf/05-split-two-streams | p29 腿 5（多汇 = 多条管道读同一来源） |
| `primitives/merge` | primitive | ported | examples/sdf/06-merge-two-sources | p29 腿 6 |
| `primitives/key-value` | primitive | ported | examples/sdf/07-key-value-keys | p29 腿 7 |
| `primitives/regex` | primitive | ported | examples/sdf/14-regex-genz | p29 腿 13–15（内核自带引擎；子集按名拒绝） |
| `primitives/custom-serialization` | primitive | ported | examples/sdf/12-custom-serialization | p29 腿 9–12（变通：`fromJSON`/`toJSON` + 恒等往返） |
| `primitives/update-state` | primitive | ported | examples/sdf/23-update-state | p29 腿 36–37/37b（**主题接力**：传感器主题 → 保存跟随者；键控行最后写入胜出 = 压实后的表；**字段级合并** = 参考 `row.update()` 语义） |
| `primitives/sql` | primitive | non-goal | — | 理由：SQL 引擎不是本项目的目标（AGENTS §9）；替代：mbel 表达式 + 状态算子（`counter`/`average`/`balance`）+ 消费者侧查询，见缺口语录 §缺口 3 |
| `packages/mask-ssn` | package | ported | examples/sdf/01-map-mask-ssn | p29 腿 1 |
| `packages/parse-sentence` | package | ported | examples/sdf/13-parse-sentence | p29 腿 8（`flatmap` 分词 + `string(len(value))` 取长度） |
| `packages/_hello-world_` | package | ported | apps/operator-identity + docs/operator-authoring-guide.md | p2 的 `build-operators.sh`（探针检查导出面）+ 作者指南（结构式等价：一个最小算子及其 ABI 面） |

## 扩展案例（**不是**参考条目：moonflux 自有，但同样在门禁里）

机器可读的状态列取值为 `ported` / `extension` / `non-goal`（`extension` = 非参考条目但同样有门禁）。
这 4 个案例回答的是参考示例集里没有直接对应物的问题（三类连接器与"日志即状态"）。它们与上表分开列
——"参考条目覆盖完了"与"我们多做了一些"是两句话，混在一起会让覆盖统计失真。

| 参考条目 | 类别 | 状态 | 我们的案例 | 门禁 / 说明 |
| :--- | :--- | :--- | :--- | :--- |
| （无对应条目） | 内核演示 | extension | examples/sdf/08-state-is-the-log | p29 腿 8（原始日志视图 vs 服务视图；键控压实保持偏移） |
| `connectors.md`（连接器文档，非 dataflow） | 连接器 | extension | examples/sdf/09-http-source | p29 腿 9–12 + p30 腿（HTTP 轮询源，对端是 `python3 -m http.server`） |
| `connectors.md`（同上） | 连接器 | extension | examples/sdf/10-mqtt-transit | p30 腿（MQTT 源/汇，独立 Python broker 断言线上字节） |
| `connectors.md`（同上） | 连接器 | extension | examples/sdf/11-kafka-bridge | p30 腿（Kafka 源/汇，独立 Python broker 断言 CRC 有效的批） |
| `dedupe` primitive（参考示例集**未使用**） | 能力补齐 | extension | examples/sdf/26-dedupe | p29 腿 42–43（去重期限 = **键的形状**：键含窗口 ⇒ 每窗去重；无键按名拒绝） |

## 部署视角的用例分类（决策 86）

`scripts/deploy-sdf.sh` 把同一份目录按**能不能无人值守地跑**分成三类，逐行写在部署根的
`catalog.tsv` 里（**没有静默跳过**）：

| 模式 | 数量 | 含义 |
| :--- | :--- | :--- |
| `run` | 5 | 单 spec、源是 file/stdin、有**单一** `expected.txt` → 跑并逐字节验证（01/02/03/04/13） |
| `run-unverified` | 3 | 跑了，但没有单一 golden（08 有 4 份视图；20/21 各有流与状态两份） |
| `deploy-only` | 18 | 多 stage（顺序按各自 README）／需要外部系统（http/mqtt/kafka）／目录里没有 spec |

容器路径按同一份分类走：一用例一容器，健康检查打 `/healthz`（决策 87）。

## 覆盖之外的三个明示非目标

| 条目 | 状态 | 理由与替代 |
| :--- | :--- | :--- |
| SQL 引擎（`primitives/sql`、各案例里的 `sql(...)` 查询） | non-goal | 见上表 `primitives/sql` 行；聚合类查询由状态算子承担（案例 18/20/21 是这条替代的实证） |
| wasm32-wasip2 / 组件模型 | non-goal | AGENTS §9 明示不做；guest 沙箱走 ABI v1/v2/v3（无导入是结构性事实，决策 16/50/60） |
| 仓库内 Rust 工具链 | non-goal | AGENTS §9；算子的作者面用 MoonBit + 发布的 C 头（决策 58）与作者指南，缺口语录 §缺口 5 记录了等价物 |

## 统计（由 `scripts/audit-sdf-coverage.sh` 核对）

- 参考条目：**26**（dataflows 12 + primitives 11 + packages 3）
- 其中 `ported` 条目：**25**（1 条 SQL primitive 明示非目标）——它们指向 **21** 个不同的案例目录
  （`mask-user-pii`/`map`/`mask-ssn` 共用案例 01，这类共享是正常的，但不该让统计含混）
- `ported` 案例目录：**21**
- **扩展案例**：**5**（moonflux 自有，见上表：08 日志即状态 + 09/10/11 三类连接器 + 26 dedupe）
- **案例合计：26** = 21（参考条目对应）+ 5（扩展）；门禁核对这个等式：
  `e2e-p29-examples.sh` 的 23 个 + `e2e-p30-connector-examples.sh` 的 3 个 = 26，与合计数一致才通过
- `non-goal`：**1** 条参考条目（`primitives/sql`）+ 2 个跨条目非目标（wasip2/组件模型、仓库内 Rust 工具链）
