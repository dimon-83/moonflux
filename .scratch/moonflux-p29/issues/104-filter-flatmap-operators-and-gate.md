# T104 · 新 guest 算子（filter / flatmap）+ P29 门禁

**What to build**:
1. `apps/operator-filter`（ABI v1）：config `{"min_len": N}` / `{"contains": "s"}`，未知键与小数 `min_len` 在 `mf_op_init` 拒绝；
2. `apps/operator-flatmap`（ABI v1）：config `{"separator": "s"}`，空分隔符拒绝，token 继承源记录 key/timestamp/headers；
3. `apps/operator-sdk` 增 `config_int`（JSON 数字是 double，这里唯一做类型化与小数拒绝的地方）；
4. `scripts/build-operators.sh` 登记两个模块；
5. `scripts/e2e-p29-examples.sh`：8 腿，逐案例字节对拍 + 案例 8b 的压实结构断言（恰好 1 段封存/恰好 1 条丢弃/地板之下 `OffsetOutOfRange`/幸存偏移不变）。

**Why the operators**: SDF 的 `filter`/`flat-map` 在 moonflux 里**不能**用 mbel 表达——表达式变换必须返回字符串，"丢弃记录"没有拼法；批算子的 `Array[Record] -> Array[Record]` 契约才让 1→0、1→N 成为结构性事实。

**Blocked by**: 无。

**Status**: ✅ 2026-10-10

**Checklist**:
- [x] 两个模块 + SDK `config_int` + `build-operators.sh` 登记
- [x] 探针通过（无导入段、mf_op_* 面完整）
- [x] 门禁 8 腿绿（含坏 config 结构化拒绝的旁证：冒烟时确认）
- [x] `gates.sh` 纳入为第 45 步
