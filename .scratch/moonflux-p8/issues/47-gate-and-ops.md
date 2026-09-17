# 47 — 门禁 + 运维面 + 留痕

**What to build:** 一条存储门禁把上面三条钉住，并让运维面看得见段：`cluster segments --topic T
[--partition N] --remote <leader>` 输出每段 `base 记录数 字节数`；矩阵 #10 收尾；README 决策 31。

**Blocked by:** 44, 45, 46.

**Status:** ready-for-agent

- [ ] `scripts/e2e-p8-storage.sh`（≥6 腿）：① 滚动产生多段且 `cluster segments` 可见 ② 跨段读取与
      "单段历史"一致（把同一批记录写进不滚动的日志作对照，逐字节/逐记录 diff） ③ 索引路径 == 全扫路径
      （删掉 `.idx` 再读一次，结果必须相同） ④ retention 按 floor 删整段：删掉后老偏移读为结构化拒绝，
      floor 之上的数据仍在 ⑤ 撕裂尾：手工截断最后一段 → 恢复只丢尾部且**前段不受影响** ⑥ 复制跨段：
      follower 的段文件是 leader 的字节前缀（沿用 P3 的对拍方式，跨段版本）
- [ ] 纳入 `scripts/gates.sh`；`docs/compatibility-matrix.md` #10 收尾（段滚动/索引/retention 三项转 ✅）
- [ ] README 路线图 P8 行 + 决策 31（retention 的 floor 语义：为什么"安全下界"必须由应用给出，
      以及为什么永不删活动段）；AGENTS §2 P8 行 + 存储纪律块
