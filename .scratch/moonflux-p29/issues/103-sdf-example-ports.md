# T103 · SDF 示例集 → moonflux 应用案例（examples/sdf/*）

**What to build**: `examples/sdf/` 下 8 个案例，每个含 `spec.json` + `input*/expected*` 夹具 + `README.md`（注明 SDF 出处、运行命令、差异），以及顶层 `examples/README.md` 索引：
01 map/mask-ssn（函数集资产）· 02 filter（1→0 算子）· 03 filter-map（跨引擎链）· 04 flat-map（1→N）· 05 split（两条入口 spec）· 06 merge（同一主题）· 07 key 语义 · 08 日志即状态（服务视图 vs 原始日志 + 键控压实）

**Blocked by**: T104（02/03/04/05/07 需要 filter/flatmap 算子制品）。

**Status**: ✅ 2026-10-10

**Checklist**:
- [x] 逐案例夹具与期望输出（字节级）
- [x] 每例 README 说明 SDF 出处 + 运行命令 + 语义差异
- [x] `examples/README.md` 索引（案例 × SDF 出处 × 门禁腿）
- [x] 案例 8 的两条运维事实写进 README（压实只动封存段；地板之下是结构化拒绝）

**Evidence**: 由 T104 的门禁 8 腿覆盖。
