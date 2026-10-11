# 18 · unreal-engine-analytics — per-label counts, and 10-second windows

**Ported from** `stateful-dataflow-examples` 的 `dataflows/unreal-engine-analytics`：UE5 游戏把分析事件
送进 `tudi-analytics-events`，counters 管道把事件名映射成标签（`assign-key`）并累加（`update-state`），
另一个 dataflow 把计数按 **10 秒 tumbling 窗口**聚合成仪表盘的表。

夹具是参考包里的样本 **原样**：`samples/sample-sdf-events.jsonl`（183 条事件，`event_name` +
`attributes`）。它没有时间字段，所以窗口管道用同一批事件加一个事件时间 `ts`（epoch 毫秒，间隔 1 秒）
—— 理由见下面的"如实边界"。

```bash
EXE=_build/native/debug/build/apps/cli/cli.exe
# 1. 每标签计数（映射表与参考实现一致）
$EXE pipeline run --data-dir "$(mktemp -d)" --spec examples/sdf/18-unreal-engine-analytics/spec-counters.json
$EXE consume --topic event-counts --from 0 --data-dir "$DATA" | awk -F'\t' '{last[$3]=$4} END {for (k in last) print k"\t"last[k]}'
# jump 113 · other 16 · sample_location 38 · session_start 8 · session_end 8
# 2. 每标签 × 每 10 秒窗口
$EXE pipeline run --data-dir "$(mktemp -d)" --spec examples/sdf/18-unreal-engine-analytics/spec-windows.json
# jump@1700000000000 = 8 · jump@1700000010000 = 6 · jump@1700000020000 = 9 · …
```

| 参考实现 | moonflux |
| :--- | :--- |
| `flat-map` + `tudi-counter-enhance`（把事件规范化/展开） | 样本已经是每行一个事件，所以这一步在本案例中没有对应物（换个输入就需要 flat-map，见案例 13/17） |
| `partition.assign-key`（`event_name` → 标签的 match 表） | `apps/operator-keyfield`（`{"field":"event_name","map":{…},"default":"other"}`） |
| `update-state`（`event_count_tbl().count += 1`） | `apps/operator-counter`（ABI v3：状态 = 该标签在状态主题里的条目） |
| 10 秒 tumbling 窗口聚合 | `apps/operator-tumble`（`window_ms=10000`）+ 同一个计数器：**窗口就是键**（`jump@1700000000000`） |

## 如实边界

1. **窗口用的是事件时间，不是处理时间**。参考实现的窗口 dataflow 用 `datetime.timestamp_millis()`
   **读时钟**来给记录打时间；我们的变换**不读时钟**（内核红线，决策 33：能进 pass/fail 的计量必须是
   确定性的）。所以窗口管道的夹具**自带** `ts`：没有时钟时，唯一诚实的窗口测试办法就是让数据带时间。
   这条与 `docs/operator-abi-v3-state.md` §5 的边界是同一条（无 idle 触发器，窗口只随数据推进）。
2. **映射表外一律 `other`**。参考实现的 `_ => "other"` 是 catch-all；`operator-keyfield` 的
   `default` 就是它（写这个案例时抓到一处**文档与实现不一致**——实现曾经在映射表外回落到原始字段值，
   而文档写的是 `default` 优先；现在两者一致，冻结期望也随之确定：`beginPlay`/`endPlay` 共 16 条归 `other`）。

## 这个案例顺带抓到的两件事（都是实测，不是推测）

1. **每次调用的燃料预算需要宿主来尊重**：183 条记录的一条批在 internal 档（50M 指令）上把燃料烧穿了
   （实测 ~312k 指令/记录，即 ~160 条触顶）——而"燃料是**每次调用**的预算"意味着**宿主不该把无界的批
   交给 guest**。修法在宿主侧：一次调用最多 `MOONFLUX_OP_BATCH_RECORDS`（默认 128）条记录，批内的
   多次调用各自成一次事务（README 决策 63）。这是策略旋钮，不是语义承诺——算子本来就不能假设一次
   pull 的全部记录会一次到达（文件源是一大批、HTTP 轮询是小批）。
2. **只要一个字段，不该付整份解析的钱**：`apps/operator-sdk/json_field.mbt` 是结构感知的定向读取器
   （跟踪字符串/转义/嵌套深度），它**不会**被"字段名出现在某个字符串值里"骗到（wbtest 专门钉住这条，
   这正是子串搜索会失败的地方）。需要嵌套路径的算子（银行事件规范化器）继续用整份解析——这个分工是
   显式的。

冻结期望：`expected-counters.txt`（183 行逐事件计数）、`expected-final-counts.txt`（收敛后的标签计数）、
`expected-windows.txt`（183 行窗口计数）、`expected-window-state.txt`（53 个 `标签@窗口起点` 状态条目）。
