# 17 · bank-processing — per-account balances, and who is in the red

**Ported from** `stateful-dataflow-examples` 的 `dataflows/bank-processing`：业务事件
（开户、存款、取款、转账）被规范化成 debit/credit 事件，按账户累加余额，并把透支事件
送到单独的主题。参考实现的样本数据（8 个 JSON 事件，Duncan 与 Lucy 两个账户）**原样**
搬进了 `events.jsonl`（按 `timestamp` 排序）。

```bash
EXE=_build/native/debug/build/apps/cli/cli.exe
D=$(mktemp -d)
$EXE pipeline run --data-dir "$D" --spec examples/sdf/17-bank-processing/spec-balance.json
# 10 行：每个受影响账户一条（开户 2 + 存取 4 + 转账 4）
$EXE consume --topic account-balance --from 0 --data-dir "$D" | awk -F'\t' '{last[$3]=$4} END {for (k in last) print k"\t"last[k]}'
# GB36MWIE43141216656969  2610     (Lucy)
# GB56DVTE70858022060682  770      (Duncan)
```

| 参考实现 | moonflux |
| :--- | :--- |
| `admin-service` / `withdrawal-service` 等 4 个服务 + 6 个主题 | **一条变换链**（我们的链是进程内的；中间主题不存在——需要多路时用"多条管道读同一来源"，见案例 05） |
| `map`/`filter-map`/`flat-map` 把业务事件拆成 debit/credit 事件 | `apps/operator-bankevents`（1→1 或 1→2，**给输出设 key**） |
| `update-state` 在 `account-balance` 状态对象上做加法 | `apps/operator-balance`（ABI v3：状态是该 iban 在状态主题里的条目） |
| 透支事件发到 `overdraft-events` 主题 | 余额算子输出里带 `"overdraft":true|false`，第二条管道用过滤器选出（`spec-overdraft.json`） |

**为什么必须先拆成 debit/credit（这不是风格问题）**：宿主把状态交给状态算子时，只给
**本批记录键**对应的条目。一笔转账影响两个账户，若把它留作一条记录（键只能是其中一个），
另一个账户的余额就会从"零"算起并被写回去——那是账目错乱，不是舍入问题。所以"一个事件
→ 每个受影响账户一条带键记录"是这套状态模型的要求，也正好是参考实现里 debit/credit 拆分的
存在理由。

## 透支路径（`events-overdraft.jsonl`）

样本数据本身不会透支（最终 Duncan 770 / Lucy 2610），所以另加一份**只多一笔取款**的夹具
（`T00000099`，Duncan 取 900 → -130），用来走通真正的透支分支：

```bash
$EXE pipeline run --data-dir "$(mktemp -d)" --spec examples/sdf/17-bank-processing/spec-overdraft.json
# {"iban":"GB56DVTE70858022060682","balance":-130,...,"overdraft":true}
```

**如实说明**：选流用的是 `operator-filter` 的 `contains` —— 一次**字节级**子串匹配，匹配的
是余额算子输出的**规范 JSON**（字段顺序固定、布尔为字面量 `true`）。它有效且被门禁钉住，
但它不是结构化的 JSON 谓词；要按任意字段做数值/相等判断（车流案例的"超速"也会想要它），
需要的是一个新的谓词算子，**尚未实现**，已列进缺口追平清单（`docs/sdf-gap-closure-plan.md`）。

## 两处如实差异

1. **金额只支持整数**：样本数据是整数。小数金额被**按名拒绝**而不是四舍五入——账本里
   静默丢掉分位不是算子有权做的决定。
2. **状态主题是写入历史**：`expected-state.txt` 冻结的是 10 条写入（每笔一次）。
   压实会把它收敛成"每键最新"（案例 08 与 `scripts/e2e-p31-state.sh` 腿 2 是那条证据）；
   `expected-final-balances.txt` 就是收敛后的形状。

冻结期望：`expected-balance.txt`（10 行余额流）、`expected-final-balances.txt`（每账户最终余额）、
`expected-state.txt`（状态主题写入历史）、`expected-overdraft.txt`（透支流，1 行）。
