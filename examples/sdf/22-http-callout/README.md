# 22 · http-callout — calling the world, on purpose

**Ported from** `stateful-dataflow-examples` 的 `dataflows/http-callout`：读 `car` 事件，按
`maker` 调一个 HTTP 服务取回厂商信息（国家/大洲）并发出。

```bash
EXE=_build/native/debug/build/apps/cli/cli.exe
O=examples/sdf/22-http-callout
$EXE pipeline run --data-dir "$(mktemp -d)" --spec $O/spec-replay.json
# {"maker": "Fiat", "country": "Italy", "continent": "Europe"}
# {"maker": "Toyota", "country": "Japan", "continent": "Asia"}
# …
```

`mode` **必填**（`live` / `record` / `replay`），没有默认值——这是本能力最核心的一条设计：

| mode | 做什么 | 什么时候用 |
| :--- | :--- | :--- |
| `live` | 真的发请求 | 你要的就是网络 |
| `record` | 发请求并把每次交换追加进磁带 | 造夹具 |
| `replay` | **只读磁带，完全不碰网络** | 门禁、复现、离线 |

```json
{ "type": "callout", "method": "GET",
  "url": "http://127.0.0.1:18089/api/maker/{maker}",
  "mode": "replay", "cassette": "examples/sdf/22-http-callout/cassette.jsonl" }
```

## 为什么必须有这个选择，而不是"默认就是活着调用"

参考实现的 `sdf_http::get(url)` 是**算子内部**的能力：每次运行都真的联网，于是同一个 dataflow
在不同时刻会给出不同结果。moonflux 的红线是**能进 pass/fail 的计量必须确定性**（决策 33），所以：

- **不给默认值**：写了 callout 就必须说清是哪一种；缺 `mode` 在 **apply 期按名拒绝**（门禁腿 1）。
- **磁带是产物，不是手写品**：`spec-record.json` 对本地 mock 跑一遍生成 `cassette.jsonl`
  （门禁腿 3），随后 `replay` 在**对端已停**的情况下逐字节复现同一答案（腿 4）。
- **未命中就拒绝**：磁带上没有那次交换 → 按名报错且零输出，**绝不返回空的 200**（腿 5）。

## 三条纪律（都是实测触发的）

1. **凭据永不进磁带**：`headers` 里的 `${VAR}` 在 **apply 时**从节点环境展开（"凭据从哪来"是宿主层
   的决定），而磁带只记 method / URL / 请求体 / 响应体——**不记 headers**。门禁腿 6 同时断言两件事：
   对端**确实看到了** `Authorization: Bearer …`，而磁带里**找不到**那个 token。
2. **出站调用必须有期限**：`timeout_ms`（默认 2000ms）装在 socket 读超时上。腿 7 指向一个会挂住的
   端点，断言"按名失败且零输出"——**宁可失败，不可挂住**（P12 的那条纪律在宿主侧同样成立）。
3. **占位符只认 `{标识符}`**：`{maker}`、`{value}` 是占位符；**其它花括号是字面量**。这条是写门禁时
   被真实数据逼出来的：POST 的 JSON 体以 `{` 开头，第一版扫描器一路找到第一个 `}`，把
   `{"model":"{model}"}` 解析成了字段 `"model":"{model`——模板语言和 JSON 体撞在一起时，规则必须写死。

## 顺带修掉的一个既有缺陷

写腿 1 时发现 **spec 拒绝信息打到了 stdout**（`pipeline run` 的 stdout 是 sink 的数据流，下游常按列
解析）。已改为 **stderr**（`warn`），与仓库"stdout 是数据流、诊断一律 stderr"的纪律一致。

## 与参考实现的差异

- **调用发生在宿主，不在算子里**：guest **没有 import 段**（结构性事实，宿主"纯函数"假设的基础），
  所以它不可能联网。callout 因此是**宿主侧变换**（`pipeline plan` 把它显示为 `host-io` 能力，腿 8），
  这对"哪些节点会离开进程"是一个可见的、可审计的答案。
- **响应体就是新记录的值**（键与时间戳保留），与参考实现一致。
- **夹具/对端**：`scripts/http_mock.py` 是门禁用的独立 Python 对端（记录每个请求以便断言
  "服务端看到了什么"），形状取自参考实现文档里的 `/api/maker/<name>`。

冻结期望：`expected.txt`（4 行厂商信息）、`cassette.jsonl`（4 次真实交换的记录）。
