# 45 — 稀疏索引

**What to build:** 每段一份 `.idx` 稀疏索引（每 N 条记录或每 M 字节记一条 `offset→position`），
`read(from)`/`read_raw(from)` 先按段表定位，再按索引跳到最近锚点向前扫描——不再整文件读入。
**正确性优先**：索引只是加速器，缺失/损坏/不一致时回退全扫，且两条路径结果必须逐字节一致（门禁对拍）。

**Blocked by:** 44.

**Status:** ready-for-agent

- [ ] `core/log`：索引格式（记录数 + 每条 `(offset:varint, position:varint)`）、构建（追加时顺手记录锚点）、
      加载与校验（段大小/锚点单调；不合法即回退）
- [ ] `SegmentFile` 增追加/读取索引的能力，或由 `SegmentStore` 提供 `index_file(base)`（二选一，实现时定并留痕）
- [ ] `read`/`read_raw` 走索引：段内 seek → 前扫；跨段继续；`read(0)`、`read(from=段边界)` 等边界用例
- [ ] 单测：索引路径与全扫路径结果一致（随机起点/长度）；索引被截断/写坏 → 回退且结果不变；索引与段的
      偏移不一致（人为篡改）→ 回退而非错答
