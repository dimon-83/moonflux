# 55 — 门禁 + 留痕

**What to build:** `scripts/e2e-p11-assets.sh`（≥5 腿）：① 只在 SC apply 一次 → 两个 spu 各自运行新规则
② 心跳只带修订（修订不变时节点不重复拉取——日志可证）③ 新节点加入后自动取得当前修订 ④ 控制面不可达时
节点保留手上的管道继续服务 ⑤ 函数集只在 SC 创建 → 引用它的 spec 在两个节点上都能编译运行 ⑥ 修订不回退。

**Blocked by:** 52, 53, 54.

**Status:** ready-for-agent

- [ ] 纳入 `scripts/gates.sh`；README 决策 34（资产权威在控制面、节点是缓存、pull 而非 push、修订不回退）
      + 路线图 P11 行；AGENTS §2 P11 行与纪律块
- [ ] 既有逐节点 apply 的门禁保持不变（单机口径仍在：`serve` 无控制面时自己 apply）
