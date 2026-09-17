# 38 — 门禁与决策记录

**Blocked by:** 36、37.

**Status:** done (2026-09-17)

- [x] `scripts/e2e-p6-functions.sh`：① 部署 + list（版本单调）② spec 引用 + 自定义函数变换记录
      ③ 缺失集合 apply 拒绝 ④ 集合外函数 apply 拒绝 ⑤ `now` 函数体 apply 拒绝 ⑥ 集合更新 +
      re-apply 生效（版本可见）；纳入 `scripts/gates.sh`
- [x] README 决策 30（函数集资产化：信任边界、纯度策略、与算子的治理同构、沙箱路线图）
- [x] AGENTS §8 增补函数集纪律（资产化/纯度/re-apply 语义）

### 关账（2026-09-17）

落地：`scripts/e2e-p6-functions.sh`（**10 条断言**，已注册进 `scripts/gates.sh`）；README 路线图 P6 行 +
决策 **27**（函数集资产）+ **28**（ABI v2 设计稿）+ 资产索引 + 待办；AGENTS §2（阶段表补齐 P4/P5/P6 +
P6 规则资产纪律块）与 §8.2（函数集纪律）。

**门禁覆盖**：① 部署/列表/取回带单调 revision（deployed→updated）② 不纯 body 在部署被拒
③ 未知字段资产被拒 ④ 引用缺失集合 apply 被拒 ⑤ 集合外函数名 apply 被拒 ⑥ 三元可用 / 顶层 `if {}`
被拒（语法面两侧）⑦ 服务端消费路径按函数变换 ⑧ 单进程 `pipeline run` 路径同规则 ⑨ 集合更新后未
re-apply 行为不变、re-apply 后变化且 `topology.json` 记到 revision 3 ⑩ 删除集合后 apply 失败。