# 24 · openai-callout — a POST callout, and counting attempts per model

**Ported from** `stateful-dataflow-examples` 的 `dataflows/openai-callout`：输入是
`[model] 句子` 这样的文本行（首个词是已知模型就用它，否则用默认模型），POST 给聊天接口，
并按模型累计**调用次数**。

```bash
EXE=_build/native/debug/build/apps/cli/cli.exe
O=examples/sdf/24-openai-callout
OPENAI_API_KEY=sk-… $EXE pipeline run --data-dir "$(mktemp -d)" --spec $O/spec-replay.json
# 1  1  2  3     ← 第 1 条 gpt-3.5-turbo、第 2 条 gpt-4、第 3 条 gpt-3.5-turbo（=2）、第 4 条 gpt-3.5-turbo（=3）
```

| 参考实现 | moonflux |
| :--- | :--- |
| `parse_model`（首个词是已知模型就用它，否则默认 + 白名单校验） | `apps/operator-modelreq`（`{"default_model":…,"models":[…]}`）——**模型清单是配置而不是硬编码**：一个部署能调哪些模型是运维决定，guest 悄悄替它决定就无法审计；清单为空在 init 期拒绝 |
| `sdf_http::post` + `Authorization: Bearer <env>` | `{"type":"callout","method":"POST","body":"{\"model\":\"{model}\",\"input\":\"{input}\"}","headers":{"Authorization":"Bearer ${OPENAI_API_KEY}"}}`（决策 66） |
| `count-per-model` 键控状态累加 | `keyfield(model)` + `operator-counter`（ABI v3），**键取自调用返回的 `model`** —— 与参考一致：计数的是**实际发出的模型** |
| 每次运行都真的调接口 | `mode` 必填：`record` 造磁带、`replay` 离线复现、`live` 真调 |

## 门禁里被钉住的三件事（都有实测证据）

1. **请求形状**：对端（`scripts/http_mock.py`）看到 4 次 `POST /v1/chat`，**body 与模型的对应关系**逐条正确
   —— `hello world` → `gpt-3.5-turbo`、`gpt-4 hello world` → `gpt-4`、`gpt-3.5-turbo tell me a joke` →
   同名模型、`hello again` → 默认；这四条恰好覆盖了"首个词判模型 + 默认回落"两个分支。
2. **凭据出得去、进不了磁带**：对端看到 `Authorization: Bearer …`，而 `cassette.jsonl` 里 grep 不到它
   （磁带只记 method / URL / 请求体 / 响应体）。
3. **离线可复现**：停掉对端后 `spec-replay.json` 给出与 `record` **逐字节相同**的答案。

**如实说明**：输入整行都进了 `input`（与参考一致）；接口怎么解释自己的输入是它的事，这个算子不是别人
API 的解析器。夹具是 4 行文本（参考 README 的两种写法各两条），响应来自本地 mock——真实 OpenAI 的
响应体形状不同（`choices[0].message.content`），**我们把响应体原样当作新记录值**，所以要对真实接口做
字段映射，是在 callout 之后加一个 map 算子的事，不是 callout 的事。

冻结期望：`expected.txt`（4 行计数）、`expected-counts.txt`（每模型最终计数）、`cassette.jsonl`（4 次真实交换）。
