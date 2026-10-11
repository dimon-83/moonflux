# 23 · update-state — the primitive itself: a keyed row, last write wins

**Ported from** `stateful-dataflow-examples` 的 `primitives/update-state`：把多个传感器的温度收集成
一张按 `id` 键控的表（`arrow-row`：`sensor` + `temperature`），示例用 `show state` 展示结果。

夹具就是参考包的 `sample-data/data.txt` **原样**（4 条，其中 `id 0` 出现两次）。

```bash
EXE=_build/native/debug/build/apps/cli/cli.exe
O=examples/sdf/23-update-state
D=$(mktemp -d)
$EXE pipeline run --data-dir "$D" --spec $O/spec-update-state.json
# 4 条照原样发出（加载器可观测，见案例 19 的说明）
$EXE consume --topic temperature --from 0 --data-dir "$D"          # 写入历史：4 条
# 0 → {"sensor":"SF","temperature":47}   ← 第二次写入胜出
# 1 → {"sensor":"LA","temperature":38}
# 2 → {"sensor":"MO","temperature":65}
```

**这个 primitive 在 moonflux 里不需要新算子**：它的语义是"把这条记录摊在一个键下面，后来的覆盖先前的"
——那正是**键控状态主题 + 每键最新**（压实的语义，决策 38/60）。所以链条只有两步：
`keyfield(id)`（键来自记录，这是平台规则）+ `loadtable(key_field=id, value_fields=[sensor,temperature])`
（把选定的字段写成该键的状态值）。

| 参考实现 | moonflux |
| :--- | :--- |
| `assign-key(event.id)`（键是 `u64`） | `keyfield(field=id)`；**数字键按整数字符串化**（状态键按契约是文本——写这个案例时发现 `loadtable` 只收文本键而 `keyfield` 收数字，两者不一致，已统一） |
| `update-state`：`temp.sensor = …; temp.temperature = …; temp.update()` | `loadtable`：键 + 选定字段的 JSON 行，每键一次写回 |
| `show state` 看到的那张表 | 状态主题**压实后的形态**（每键最新）——门禁同时断言**写入历史 4 条**与**表 3 行** |
| 没有 sink（只在 `show state` 里可见） | 加载器把记录照原样发出，于是"表写好了"这件事在流里可见 |

**如实说明**：参考的 `update-state` 是**在 SQL/表之上**的更新（`row.update()` 语义含字段级合并）；这里是
**整行覆盖**（`loadtable` 用本记录选定的字段重写该键的值）。对"最后一条记录决定该键整行"的示例数据，
两者结果完全一致；**部分字段更新**（只更新 `temperature` 而保留 `sensor`）在我们这里需要算子先把旧行读进来
再合并——能力已具备（v3 状态进出），但没有现成算子，如实留档而非假装等价。

冻结期望：`expected-stream.txt`（4 行）、`expected-state-history.txt`（写入历史）、`expected-table.txt`（压实后的表）。
