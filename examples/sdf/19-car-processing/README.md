# 19 · car-processing — speeding, locations, colour windows, stolen plates

**Ported from** `stateful-dataflow-examples` 的 `dataflows/car-processing`：读 `cars` 与 `licenses`
两个主题，做四件事——识别超速（`filter-map`）、按地点切流（`split`）、按颜色做 **30 秒 tumbling
窗口**计数、以及用**参考状态**比对被盗车牌。

**夹具是合成的**：参考实现从 `demo-data.infinyon.com` 的合成数据生成器实时拉取，所以本案例按它
README 里记录的 schema 造了 10 辆车 + 6 张登记牌照（时间戳跨 3 个 30 秒窗口；含一辆**套牌车**：
Fiat 500 挂着登记在 Toyota Camry 名下的 `0VTI452`）。这一点写在最前面，因为它与"参考样本原样搬运"
的前几个案例不同。

```bash
EXE=_build/native/debug/build/apps/cli/cli.exe
O=examples/sdf/19-car-processing
DATA=$(mktemp -d)
$EXE pipeline run --data-dir "$(mktemp -d)" --spec $O/spec-speed.json          # mph>60：6 条
$EXE pipeline run --data-dir "$(mktemp -d)" --spec $O/spec-location-sunnyvale.json  # 2 条
$EXE pipeline run --data-dir "$(mktemp -d)" --spec $O/spec-location-saratoga.json   # 4 条
$EXE pipeline run --data-dir "$(mktemp -d)" --spec $O/spec-color-windows.json  # 每色 × 每 30 秒窗口
# 参考表：先加载，再比对（两条管道共享同一条状态主题）
$EXE pipeline run --data-dir "$DATA" --spec $O/spec-licenses.json
$EXE pipeline run --data-dir "$DATA" --spec $O/spec-stolen.json
# {"license":"0VTI452","owner":"Fiat 500","violator":"Toyota Camry"}
```

| 参考实现 | moonflux |
| :--- | :--- |
| 超速 `filter-map`（`mph > 60`） | `apps/operator-predicate`（`{"field":"mph","op":"gt","value":60}`）——**结构化谓词**，正是缺口 10 补上的那个算子 |
| `split` 按地点 | 两条管道读同一来源，各自用谓词选地点（与案例 05 同一手法） |
| 30 秒 tumbling 窗口 + 按色 `update-state` | `keyfield`（键=颜色）→ `tumble(30s, ISO-8601)` → `counter`：**窗口就是键** |
| `save-license-plates`（参考状态表） | `operator-loadtable`（键 = 牌照，值 = `{"maker","model"}` 的 JSON 行） |
| `check-license-plates`（牌照在表里但 maker/model 不符 = 套牌） | `operator-stolenplates`（**只读**：返回空的状态更新列表） |

## 三处如实差异

1. **窗口的产出形状**：参考实现在**窗口关闭时 flush** 一个列表（`SELECT * FROM count_by_color`，
   一次给出该窗口所有颜色的总数）。**我们没有"窗口关闭"这个事件**——本设计里窗口只因"来了属于更晚
   窗口的记录"而更换，没有 idle/时钟触发器（`docs/operator-abi-v3-state.md` §5）。所以我们按记录输出
   该颜色的**运行总数**：每个窗口最后一条记录携带的就是那个窗口的最终值，其余在状态主题里。数据相同，
   载体不同，而且这个差异来自一条明确的边界，不是实现偷懒。
2. **加载器是可观测的**：参考的 `save-license-plates` 没有 sink（纯写状态）；我们的 `operator-loadtable`
   把它加载的行**照原样发出**，这样"表加载好了"这件事流（和门禁）才看得见。
3. **ISO-8601 事件时间是新能力**（顺带落地）：`tumble` 现在支持 `"time_format": "iso8601"`
   （`YYYY-MM-DDTHH:MM:SS[.fff]Z`）。它是**纯算术**（civil-days 换算），所以不违反"算子不读时钟"；
   **必须带 `Z`**（我们没有时区数据库，给裸时间戳编一个偏移正是窗口该拒绝的猜测）；**亚毫秒精度按名拒绝**
   而不是截断；闰年/世纪规则有 wbtest 钉住（含 1969 年那种负纪元）。

## 顺带被抓到的一条平台规则（写进 spec 的写法里）

`spec-licenses.json` 的第一个变换是 `operator-keyfield`（键 = `license`）——**不是冗余**：宿主把状态
交给状态算子时只给"本批记录键"对应的条目，所以**任何状态节点都必须先有键**，而键来自记录；把字段变成
键的算子就是 `operator-keyfield`/`operator-wordkeys` 这类。第一次跑加载器时正是被这条规则按名拒绝的
（"a stateful operator needs a key on every record"），这比让加载器自己猜键要诚实。

冻结期望：`expected-speed.txt`、`expected-location-{sunnyvale,saratoga}.txt`、
`expected-color-windows.txt` + `expected-color-state.txt`、`expected-licenses.txt` +
`expected-license-state.txt`、`expected-stolen.txt`。
