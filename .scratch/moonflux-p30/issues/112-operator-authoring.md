# T112 · 算子作者指南 + 稳定 C ABI 头（缺口 5 的作者面）

**What to build**:
1. `docs/operator-authoring-guide.md`：从 `apps/operator-identity`（hello world）逐行讲起；三种形状各指一个真实模块（upper 1→1 / filter 1→0 / flatmap 1→N / scalar ABI v2）；配置只走 `mf_op_init`（未知键拒绝、`config_int` 小数拒绝）；构建→探针→挂载；五条纪律；非 MoonBit 作者的 C 头；明确不做（WASI/wasip2/组件模型、仓库内 Rust 工具链）。
2. `apps/operator-sdk/include/moonflux_operator.h`：完整 C 面（v1 七个导出 + v2 可选成对 + 缓冲协议时序 + "i32 是线性内存偏移"）。
3. **不漂移保证**：`tools/probe_operator_exports.py` 增加头部校验——期望导出必须都在头部声明、头部不得声明 ABI 之外的名字、头部钉的 ABI 版本必须等于内核 `ABI_VERSION`。

**Blocked by**: 无。

**Status**: ✅ 2026-10-10（决策 58）

**Checklist**:
- [x] 指南 + 头部（`apps/operator-sdk/include/`）
- [x] 探针头部校验，双向反向验证：改名 `mf_op_last_error` → 红；版本号改 7 → 红；一致 → `operator ABI surface OK (modules + published header)`
- [x] 接入既有 `build-operators.sh` 第 2 步（不新增门禁步数）
- [x] README 资产索引 + 决策 58 / AGENTS §11 / feature-matrix 沙箱行 / roadmap / board / 缺口 5 状态
