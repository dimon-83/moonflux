# 47 — 门禁 + 运维面 + 留痕

**What to build:** 一条存储门禁把上面三条钉住，并让运维面看得见段：`cluster segments --topic T
[--partition N] --remote <leader>` 输出每段 `base 记录数 字节数`；矩阵 #10 收尾；README 决策 31。

**Blocked by:** 44, 45, 46.

**Status:** done (2026-09-17)

- [x] `scripts/e2e-p8-storage.sh`（≥6 腿）：① 滚动产生多段且 `cluster segments` 可见 ② 跨段读取与
      "单段历史"一致（把同一批记录写进不滚动的日志作对照，逐字节/逐记录 diff） ③ 索引路径 == 全扫路径
      （删掉 `.idx` 再读一次，结果必须相同） ④ retention 按 floor 删整段：删掉后老偏移读为结构化拒绝，
      floor 之上的数据仍在 ⑤ 撕裂尾：手工截断最后一段 → 恢复只丢尾部且**前段不受影响** ⑥ 复制跨段：
      follower 的段文件是 leader 的字节前缀（沿用 P3 的对拍方式，跨段版本）
- [x] 纳入 `scripts/gates.sh`；`docs/compatibility-matrix.md` #10 收尾（段滚动/索引/retention 三项转 ✅）
- [x] README 路线图 P8 行 + 决策 31（retention 的 floor 语义：为什么"安全下界"必须由应用给出，
      以及为什么永不删活动段）；AGENTS §2 P8 行 + 存储纪律块

### 关账（2026-09-17）

`scripts/e2e-p8-storage.sh`（**7 条腿**，已注册进 `gates.sh` 第 27 步）：① 滚动产生 3 段且**精确铺满偏移空间**（基址递增、记录数求和 = 总记录数） ② 滚动日志与从不滚动日志的**读取完全一致** ③ 删掉全部 `.idx` 后读取**逐字节不变**（回退路径） ④ retention 只删 floor 以下整段、更老的读被**结构化拒绝**且理由可见、幸存窗口仍可读 ⑤ 撕裂尾恰好损失它自己那一段的记录数、**已封存段逐字节未动**（按文件名对拍） ⑥ follower 的段文件与 leader **逐段字节一致** ⑦ 端口预检（陈旧进程占端口会让断言测到另一个 broker 的数据——这次调试里真实踩到，故加为前置检查）。

运维面：`cluster segments --topic T [--partition N] --remote <leader>`（协议加法命令 26），逐段输出 `base 记录数 字节数`。

**顺带修复**：恢复告警原本用 `println` 输出，被长驻进程的块缓冲吞掉（日志里看不到的告警等于没有）→ 改走会 flush 的 `note()`；P3/P4/P5 三处门禁按段布局更新（`e2e-p3-failover` 的"追平字节一致"此前是**空比较**——声明了 helper 却从未调用，现在真的调用并要求非空）。
