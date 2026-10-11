# 25 · hackernews-notify — words, subscribers, and matching articles

**Ported from** `stateful-dataflow-examples` 的 `dataflows/hackernews-notify`（示例集里拓扑最复杂的一个）：
用户把「词 + 邮箱」登记进一张**键控订阅表**（按词去重），HackerNews 文章标题按词展开，命中订阅的词
就为**每一位订阅者**产出一条通知事件。

```bash
EXE=_build/native/debug/build/apps/cli/cli.exe
O=examples/sdf/25-hackernews-notify
D=$(mktemp -d)
$EXE pipeline run --data-dir "$D" --spec $O/spec-subscribe.json     # 4 条请求 → 2 个词
$EXE consume --topic notify-table --from 0 --data-dir "$D"
# rust    ada@example.com,bob@example.com     ← 第 4 条请求重复订阅 ada，没有加第二次
# fluvio  ada@example.com
$EXE pipeline run --data-dir "$D" --spec $O/spec-notify.json       # 3 篇文章 → 5 条通知
# {"email":"ada@example.com","word":"rust","link":"…/1","title":"Rust in the kernel"}
# {"email":"bob@example.com","word":"rust","link":"…/1","title":"Rust in the kernel"}
# … 第二篇命中 fluvio(ada) + rust(ada,bob) 共 3 条；第三篇无人订阅 → 0 条
```

| 参考实现 | moonflux |
| :--- | :--- |
| `process-user-request`：`assign-key(word.to_lowercase())` + `update-state`（往 `email-list` 追加，已存在则不加） | `keyfield(field=word, lowercase=true)` + **`apps/operator-subscribe`**（ABI v3：状态 = 逗号分隔的去重邮件列表） |
| `process-articles` 的 `flat-map`（`title.split_whitespace()` → 每词一条 ArticleData） | **`wordkeys` 的新 `field` 选项**（`field=title` + `keep_value=true` + `lowercase=true`） |
| `filter-map`：按词查 `notify_table`，命中才继续 | **`apps/operator-notify`**（ABI v3，**只读**：命中的词 → 每位订阅者一条事件） |
| 第三个 `flat-map`：把 `email-list` 拆成多条事件 | 同一个算子内部完成（事件形状 `{email, word, link, title}`） |
| 两个服务 `states: ... from:` 共享订阅表 | 两条管道指向**同一条状态主题**（`notify-table`）——与案例 16 同一手法 |

**凭什么说匹配是真的**（门禁腿 40/41）：订阅管道的状态表恰好是两行、且 `rust` 的列表是
`ada,bob`（重复订阅**没有**变成第三次）;通知管道恰好 5 条，逐字节对拍——其中 `fluvio` 只有 1 位订阅者、
`rust` 有 2 位，第三篇文章 0 条。**如果去重漏了**（rust 列表里有三个 ada），通知就会多出两条，
门禁会红——所以"去重"这条不是靠读代码相信，是被输出钉住的。

## 写这个案例时抓到的两件事

1. **`wordkeys` 拆错了对象**：它拆的是**整条值**，而文章的值是 JSON——第一次跑出来的"词"是
   `{"title":"rust`、`kernel","link":…` 这样的 JSON 碎片。参考实现拆的是 `article.title`，所以给
   `wordkeys` 加了 `field` 选项（拆某个 JSON 字段的文本）。**这类错误不会报错，只会给出看起来像词的垃圾**
   ——正因为门禁逐字节对拍，它才现形。
2. **大小写归一是一处显式选项**：参考在 `assign-key` 与查询两侧都 `to_lowercase()`；我们给
   `keyfield`/`wordkeys` 都加了 `lowercase`（默认关）。夹具故意用 `"Rust"` 与 `"rust"` 各一次订阅，
   门禁的表里只有一行 `rust` —— 归一化生效的证据在输出里。

**如实说明**：夹具是**合成的**（参考实现从 HackerNews 抓取 + 用户请求来自外部），但严格按它的
`article` / `user` / `notify-event` 三个类型构造；`email-list` 用逗号分隔（与参考一致，且邮箱里不会出现逗号，
这一点由**订阅算子按名拒绝含逗号的邮箱**保证）。

冻结期望：`expected-table.txt`（订阅表两行）、`expected-notifications.txt`（5 条通知）。
