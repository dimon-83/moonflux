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

## 服务从主题取数（决策 72）

参考实现的 `save-temperature` 服务从主题读传感器数据，本案例也这样跑：

```
spec-relay.json          file(data.jsonl)          → 空变换 → 主题 temperature-stream          （接力）
spec-update-state.json   主题 temperature-stream    → keyfield + loadtable        → stdout    （保存服务）
spec-relay-partial.json  file(data-partial.jsonl)  → 空变换 → 主题 temperature-partial-stream （接力）
spec-merge.json          主题 …partial-stream       → keyfield + loadtable(merge)  → stdout    （合并服务）
```

两个服务都是**跟随者**（追平即 `Quiet`），门禁用有界等待 + 停止它们。`spec-merge-refuse.json`
仍是**文件源**：它验的是算子对"两侧都没有的字段"的拒绝，与接力无关（有一条腿专门跑它）。

## 字段级合并（`"merge": true`）：参考 `row.update()` 的语义

参考的 `row.update()` 只写它**赋过值**的字段；默认的加载器是**整行重写**，所以一条只带 `temperature` 的
记录会把 `sensor` 抹掉。`spec-merge.json` 打开合并：**记录里没有的字段沿用已存行里的值**，两边都没有的字段
**按名拒绝**（`value field … is in neither the record nor the stored row`）——没有值可写时编一个比失败更糟。

```bash
$EXE pipeline run --data-dir "$(mktemp -d)" --spec $O/spec-merge.json
# 表：0 → {"sensor":"SF","temperature":51}   ← 两次"只带 temperature"的更新之后 sensor 仍在
#     1 → {"sensor":"LA","temperature":30}
```

夹具在**同一批**里就包含"先写整行、再只写 temperature"，这正是写这个功能时抓到的一个真问题：
宿主交给算子的状态是**批开始时的快照**，所以同批先前记录刚构造的行**不在**状态输入里——第一版因此拒绝了
自己的第二条记录。修法是算子自己维护**批内进行中的行**（这才是 `row.update()` 的语义），这条已经写进
算子的注释里，因为它是"批是一次事务"这条纪律的具体后果。

**同一轮里的一处语义收紧**：加载器现在**每批每键只写一次**（写批结束时的行），不再逐记录写——
与 `counter`/`balance`/`average` 一致，批即事务，中间行是噪声。所以案例 23 的"写入历史"从 4 条变成
**3 条**（4 条记录、3 个键），表仍是每键最后一行。

冻结期望：`expected-stream.txt`（4 行）、`expected-state-history.txt`（写入历史）、`expected-table.txt`（压实后的表）。
