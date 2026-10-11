# 21 · ny-transit — average tip per pickup zone, every 30 seconds

**Ported from** `stateful-dataflow-examples` 的 `dataflows/ny-transit`：三个服务处理
`save-vendors`（静态表）、`save-locations`（静态表）与 `build-trips-table`——后者每 **30 秒**刷新
`trips_tbl`，用 SQL 算出**每个载客区的平均小费**，写进 `pu-tips` 供可视化上色。

```bash
EXE=_build/native/debug/build/apps/cli/cli.exe
O=examples/sdf/21-ny-transit
$EXE pipeline run --data-dir "$(mktemp -d)" --spec $O/spec-pu-tips.json
# {"key":"ZoneA@1710432750000","avg_tip":3,"trips":1}
# {"key":"ZoneA@1710432750000","avg_tip":4,"trips":2}     # (3.0+5.0)/2
# …
```

| 参考实现 | moonflux |
| :--- | :--- |
| 30 秒窗口（`dropoff_datetime` 解析成时间戳） | `keyfield(PULocationID)` → `tumble(30s, dropoff_datetime, iso8601)` → `operator-average(field=tips)` |
| `SELECT ... avg(tips) ... GROUP BY pu_location_id`（SQL） | **同一个聚合，做在状态所在的地方**：状态值是 `<sum>,<count>`，两个精确输入，除一次得到均值 |
| `save-vendors` / `save-locations` 静态表 + SQL join | 夹具里保留了这两张表（`vendors.jsonl` / `locations.jsonl`）以便认出拓扑，但**它们只服务于可视化背后的 join**——SQL 是明示非目标（AGENTS §9），所以本案例移植的是**聚合主张**（每区每窗平均小费），不是 join |

## 如实说明

1. **时区**：TLC 原始文件里的 `dropoff_datetime` 是**本地朴素时间**（America/New_York）。我们的窗口
   **拒绝给裸时间戳编一个偏移**（没有时区数据库，猜偏移正是窗口该拒绝的动作——这条在决策 64 里写死了，
   这里第一次被真实数据触发：第一次跑就被按名拒绝）。所以夹具携带带 `Z` 的 UTC 瞬时，并在 README 写明：
   **把真实文件转成 UTC 是管道第一步该做的显式工作**，而不是让窗口去推断。
2. **产出形状**：参考在窗口关闭时产出（`flush` → `pu-tips`）；我们没有"窗口关闭"事件（无 idle、无时钟），
   所以按记录输出该区的运行均值，**每个 `区@窗口` 的最后一条就是该窗口的平均小费**，其余在状态主题里。
3. **平均值的状态是 `sum,count`**（例如 `8,2`）——不是自引用的均值：只记住自己的平均值无法修正，而
   `sum,count` 让"3 → 4"这种运行结果可以被手算核对（门禁就断言了 `8,2`）。
4. **夹具是合成的**（TLC 的公开数据集不在仓库里），按参考 README 链接的 schema 构造：8 程、3 个区、
   跨 3 个 30 秒窗口，含一笔 `tips: 0` 的行程。

冻结期望：`expected-stream.txt`（8 行）与 `expected-state.txt`（7 个 `区@窗口` 的 `sum,count`）。
