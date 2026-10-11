# 16 · word-probe — the same state, read by a second pipeline

**Ported from** `stateful-dataflow-examples` 的 `dataflows/word-probe`：它有两个服务，
第一个把句子切成词并累加每个词的出现次数，第二个**读同一份状态**回答探测词的数量。

**What moonflux does here**: 「状态跨服务」在本平台有一条现成的答案——**两条管道共享同一条
状态主题**。计数管道写它，探测管道读它，两边都不需要知道对方存在：

```bash
EXE=_build/native/debug/build/apps/cli/cli.exe
DATA=$(mktemp -d)
# 1. 计数：sentences → 设键(wordkeys) → 计数(counter，ABI v3)   [写 state: count-per-word]
$EXE pipeline run --data-dir "$DATA" --spec examples/sdf/16-word-probe/spec-count.json
# 2. 探测：words → 设键(wordkeys) → 查表(probe，ABI v3，只读)   [读同一 state]
$EXE pipeline run --data-dir "$DATA" --spec examples/sdf/16-word-probe/spec-probe.json
# {"word":"eyes","count":3}
# {"word":"stars","count":1}
# {"word":"the","count":4}
```

三维证据都冻结在目录里：`expected-counts-stream.txt`（计数管道的逐词流，32 行 = 三个句子
的 32 个词元）、`expected-state.txt`（状态主题的每词最新值，23 个词）、`expected-probe.txt`
（探测答案）。

## 架构说明：为什么"跨服务读"不需要新机制

SDF 的服务各自持有 `states:`，第二个服务用 `from: count-words.count-per-word` **引用**第一个
服务的状态。moonflux 的状态**本来就是一条主题**（[`operator-abi-v3-state.md`](../docs/operator-abi-v3-state.md)），
所以「引用另一个服务的状态」= **指向同一条主题名**。于是：

- 探测管道启动时**重放**该主题（宿主视图 = 缓存），因此它看到的是计数管道**已经写下**的值；
- `operator-probe` 返回**空的状态更新列表**——读就是读。门禁断言探测前后状态主题的记录数不变
  （23 → 23），否则"读"会悄悄变成"写"，两条管道就能互相踩。

**如实边界（写在这里而不是藏起来）**：探测看到的是**它启动那一刻的快照**（宿主视图只在
本进程的写入后更新，不 tail 别的进程）。所以「先计数、后探测」是对的用法；常驻探测进程不会
跟随另一个进程后续的写入。要做实时跟随，需要的是消费者侧 tail + 视图增量应用，那是另一个
能力（未立项）。

## 与参考实现的两处差异（都是有意的）

1. **大小写与标点**：SDF 的 `assign-key` 会 `to_lowercase()` 并只保留字母数字；我们的
   `operator-wordkeys` **原样**把 token 作为键。本案例的夹具全是小写英文，所以结果一致；
   换一份含大写或标点的数据，两边会给出不同的键——差异点在这里，不在结果里。
2. **缺失词的默认值**：SDF 的 `query_word_count` 查不到时返回 `count: 0`；`operator-probe`
   的 `{"missing": 0}` 是同一个默认值，且**可选**（配置里可以改成别的数，未知键仍被拒绝）。
   `spec-probe-extra.json` + `expected-probe-extra.txt` 就是这个路径的证据：探测表里加一个
   句子里没有的 `zebra`，答案里它得 0。
