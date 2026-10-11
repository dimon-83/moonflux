# 26 · dedupe — SDF 的 `dedupe` primitive（**扩展案例，不是参考条目**）

参考示例集里**没有**用到 `dedupe`（`word-counter` 是"窗口内每词 +1"，不是"每词只算一次"）。所以这个案例
不是移植：它是"SDF 有这个 primitive、我们没有"这条差异的补齐，附可证伪门禁。

```bash
EXE=_build/native/debug/build/apps/cli/cli.exe
O=examples/sdf/26-dedupe
$EXE pipeline run --data-dir "$(mktemp -d)" --spec $O/spec-windowed.json   # 7 条进 → 5 条出
$EXE pipeline run --data-dir "$(mktemp -d)" --spec $O/spec-forever.json    # 7 条进 → 3 条出
```

## 设计：去重的"期限"就是**键的形状**

`apps/operator-dedupe` 没有时钟、没有时间字段、没有窗口算术——它只做一件事：**每个键的第一条通过，
其余丢掉**（1→0，与 `operator-filter` 同一形状）。要"只在一个窗口内去重"，就让窗口成为键的一部分：

```
keyfield(user) → tumble(time_field, window_ms) → dedupe      # 键 = user@窗口起点 ⇒ 每窗各去重一次
keyfield(user) → dedupe                                      # 键 = user   ⇒ 永久去重
```

这正是平台里窗口的唯一规则（决策 61：**窗口不是第二个概念，是键的形状**），所以 dedupe 不需要为窗口
引入任何新机制。

| 夹具（7 条事件） | `spec-windowed`（键含窗口） | `spec-forever`（键 = 用户） |
| :--- | :--- | :--- |
| w0: u1, u2, **u1(重)** | u1 ✓ u2 ✓（重丢掉） | u1 ✓ u2 ✓ |
| w1: u1, u3, u2, **u1(重)** | u1 ✓（**新窗口⇒新键**）u3 ✓ u2 ✓（**同理**） | 全部丢掉（u1/u2 已见；u3 ✓） |
| 输出 | **5 条** | **3 条** |
| 状态主题 | 5 条，键形如 `u1@1700000000000` | 3 条，键 = `u1`/`u2`/`u3` |

**如实说明**：`spec-forever` 的"已见"是**永久**的，状态随**不同键数**增长——这个上界写在算子注释与
README 里，而不是藏起来：期限无界的去重应该放在一个 retention/压实策略知道这件事的主题上。

**第三条腿证明拒绝是结构性的**：不给键（`spec-nokey.json`）时，**宿主**先按名拒绝
（`a stateful operator needs a key on every record`）——算子拿不到记录，所以"忘了设键"不会变成静默的
"每批只留一条"。算子内部还有第二道（空键按名拒绝），两道都在。

冻结期望：`expected-windowed.txt` / `expected-windowed-state.txt` / `expected-forever.txt` /
`expected-forever-state.txt`；门禁 `scripts/e2e-p29-examples.sh` 末两条腿逐字节核对。
