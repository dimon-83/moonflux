# T110 · 两个新案例：custom-serialization（12）与 parse-sentence（13）

**What to build**:
1. `examples/sdf/12-custom-serialization/`：三个 spec 对应 SDF `primitives/custom-serialization/struct/{deserialize,serialize}` 的两个方向加上最强形式的"忠实"——`get(fromJSON(value), "maker")` 读字段、`toJSON(fromPairs([["car",…],["fast", get(…,"mph") > 60]]))` 按字段重写 JSON（数值按数值比较）、`toJSON(fromPairs(toPairs(fromJSON(value))))` **逐字节恒等往返**。
2. `examples/sdf/13-parse-sentence/`：SDF `packages/parse-sentence` 的两个函数端到端——沙箱 `operator-flatmap` 做 `sentence-to-words`，规则 `string(len(value))` 做 `word-length`（规则必须返回字符串，故显式 stringify）。

**Blocked by**: T108（案例 12/13 的表达式的可发布性依赖探针修复）。

**Status**: ✅ 2026-10-10

**Checklist**:
- [x] 两例夹具 + spec + expected + README（写明 SDF 出处、运行命令、差异）
- [x] `scripts/e2e-p29-examples.sh` 8 → 12 腿（腿 9–12），头部注释与汇总同步
- [x] `examples/README.md` 索引与跑法块
- [x] `docs/sdf-examples-port.md` 案例表 + 缺口 4（部分收口）/缺口 5（能力等价物已在）状态
