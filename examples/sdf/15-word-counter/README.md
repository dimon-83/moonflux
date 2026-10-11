# 15 · word-counter — top three words per 20-second window

**Ported from** `stateful-dataflow-examples` 的 `dataflows/word-counter`：句子切词 →
**20 秒 tumbling 窗口**内按词计数 → **窗口关闭时 flush 出前 3 个词**，写进 `most-used-words`。

```bash
EXE=_build/native/debug/build/apps/cli/cli.exe
O=examples/sdf/15-word-counter
$EXE pipeline run --data-dir "$(mktemp -d)" --spec $O/spec.json
# {"window_start":1700000000000,"top_words":[{"word":"the","count":4},{"word":"on","count":2},{"word":"sat","count":2}]}
# {"window_start":1700000020000,"top_words":[{"word":"the","count":4},{"word":"ate","count":2},{"word":"rat","count":2}]}
```

三条记录进了第三个窗口（`jam`），**它没有关闭，所以没有第三行**——这正是参考实现自己文档里写的边界：

> The watermark closes the window on event. Hence, if you stop adding events before the
> watermark triggers, the window stays open, and nothing gets produced. … To force the window
> to flush, produce one more record after the 20-second mark.

我们的实现与这句话**同一条语义**，而且不需要时钟：窗口关闭的判据是"来了一条属于**更晚**窗口的记录"
（`apps/operator-topwords`）。水位 = 已见最大事件时间，是**输入的函数**，所以确定性成立（决策 33）。

| 参考实现 | moonflux |
| :--- | :--- |
| `flat-map` 切词（按空白，过滤到字母数字，丢空词） | `operator-topwords` 内部做同一件事（同样过滤到 ASCII 字母数字、同样丢空词） |
| `window.tumbling.duration: 20s` + `assign-timestamp`（事件时间） | `window_ms: 20000` + `time_field`（epoch 毫秒或 **ISO-8601**，`time_format`） |
| `assign-key`（键 = 小写词）+ `update-state`（每词 +1） | 累加器（`the 4; on 2; …`）存在**一个键**下——全局聚合需要单键，所以链上有 `operator-keyconst` |
| `flush` 里的 `sql("select … order by count desc limit 3")` | `top_words` 渲染（count 降序，**并列按词升序**——否则 top-3 不确定） |
| `most-used-words` 主题 | `spec.state.topic`（累加器）+ stdout（汇总流） |

## 与参考实现的两处如实差异

1. **迟到记录按名拒绝，不静默丢弃**：参考的水位会把迟到的记录默默丢掉；我们返回
   `late record: window … is closed`——**静默丢数据是这个仓库不做的事**（门禁可断言"拒绝"）。
2. **字母数字过滤是 ASCII**：参考的 `is_alphanumeric()` 是 Unicode 感知的，我们的是 ASCII
   （`a-z A-Z 0-9`）。本案例夹具是英文，结果一致；非 ASCII 词需要另立项。

## 另一个 spec：计数的一半

`spec-counts.json` 保留"只计数不 flush"的链（`wordkeys` + `counter`），它的首跑、状态主题与**续跑**
三份期望冻结在 `expected.txt` / `expected-state.txt` / `expected-second-run.txt`——用来演示两件事：
状态主题是"每词一条最新"的真值，而**第二次运行是接着算而不是重来**。

冻结期望：`expected-summaries.txt`（两条 flush）、`expected-accumulator.txt`（未关闭窗口的累加器）、
加上计数半的三份。门禁 `scripts/e2e-p29-examples.sh` 腿 16–17 逐字节核对全部五份。
