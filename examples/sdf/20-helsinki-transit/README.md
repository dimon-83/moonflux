# 20 · helsinki-transit — average speed per vehicle, every 5 seconds

**Ported from** `stateful-dataflow-examples` 的 `dataflows/helsinki-transit`：两个服务——`clean-events`
丢掉字段不全的事件（`lat`/`long`/`speed` 都是 `optional`），`generate-vehicle-stats` 用 **5 秒 tumbling
窗口**算**每辆车的平均速度**，结果送给可视化。

夹具以参考包 **`sample/sdf.json`** 那条真实事件（`vehicle 1271 / route 1040 / speed 8.09 /
tst 2025-05-29T22:46:04.751Z`）为第一条，另加同一车队的若干条与**三条不完整事件**（分别缺 `speed`、
`lat`、`long`）——不完整的正是 `clean-events` 要丢掉的。

```bash
EXE=_build/native/debug/build/apps/cli/cli.exe
O=examples/sdf/20-helsinki-transit
$EXE pipeline run --data-dir "$(mktemp -d)" --spec $O/spec-vehicle-stats.json
# 10 条进，7 条出（3 条不完整被丢）
# {"key":"1271@1748558765000","avg_speed":11.5,"count":1}
# {"key":"1271@1748558765000","avg_speed":13.705,"count":2}   # (11.5+15.91)/2
```

| 参考实现 | moonflux |
| :--- | :--- |
| `clean-events` 的 `filter`（`lat.is_some() && long.is_some() && speed.is_some()`） | 三个 `operator-predicate`（`lat ge -90` / `long ge -180` / `speed ge 0`，都带 `missing: "drop"`）——**字段存在性判断就是 `missing` 策略**，它同时把不可能的值挡在外面 |
| `clean-events` 的 `map`（`chrono::NaiveDateTime::parse_from_str("%Y-%m-%dT%H:%M:%S.%fZ")` → 毫秒） | `tumble` 的 `"time_format": "iso8601"`（决策 64）：**纯算术**，不读时钟 |
| 按车 `assign-key` + 5 秒窗口 + 平均速度 | `keyfield(vehicle)` → `tumble(5000ms, tst, iso8601)` → `operator-average(field=speed)`：窗口就是键 |
| `states: vehicle-stat`（`route` + `speed` 的 arrow-row） | 状态值 = `<sum>,<count>` 两个数（**不是**平均值的自引用）——平均值只记住自己就无法修正 |
| 入站走 **MQTT**（HSL 的 HFP 接口） | 本案例用**文件夹具**回放同形状的记录；MQTT 传输本身在案例 10/11 的门禁里被独立断言（独立 Python broker）。同一条变换链喂 MQTT 记录是同一个链 |

## 如实差异

1. **产出形状**：参考实现在窗口关闭时产出（`flush` 平均速度清单）。我们没有"窗口关闭"事件（无 idle、
   无时钟，决策 61/64）→ **按记录输出该组的运行均值**，每个 `车@窗口` 的最后一条就是该窗口的最终均值，
   其余在状态主题里。数据相同、载体不同。
2. **缺字段 = 拒绝而不是跳过**：`operator-average` 遇到 `speed` 缺失/非数字会**按名拒绝**，而不是跳过
   那条记录继续平均——**"悄悄少平均几条却声称在平均整条流"是那种看起来对的错**。所以清理必须发生在
   它之前（这里就是三个谓词），这正是参考实现把 `clean-events` 单独设成一个服务的原因。
3. **`route` 不在状态里**：参考的 arrow-row 同时存 `route`，但它的输出只有（车, 时间窗, 平均速度）；
   我们只存做平均所需的两数——少存一个字段不是等价性损失，是"状态里不放用不到的东西"。

冻结期望：`expected-stream.txt`（7 行）与 `expected-state.txt`（6 个 `车@窗口` 条目，值是 `sum,count`）。
