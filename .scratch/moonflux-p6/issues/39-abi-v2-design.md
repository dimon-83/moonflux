# 39 — ABI v2 标量调用设计稿（只设计不实现）+ P6 关账

**Blocked by:** 37.

**Status:** done (2026-09-17)

- [x] `docs/operator-abi-v2-scalar.md`：动机（不可信标量函数进沙箱）；ABI v1 的 7 个批导出不动 +
      可选标量导出（`mf_op_scalar_abi_version` / `mf_op_eval(request) -> response`，首版 JSON 编码）；
      宿主函数注册表 `{name → module, budget}`；mbel 宿主闭包 marshal @ast.Value → JSON 逐调用执行；
      确定性由 guest 无导入结构性保证；开放问题（参数类型编码、错误分类、标量调用批量化、注册表治理）
- [x] README 决策 31（ABI v2 设计稿定调：触发条件 = 不可信标量函数需求）
- [x] P6 关账：全量回归、tickets 关闭

### 关账（2026-09-17）

交付 `docs/operator-abi-v2-scalar.md`（只设计不实现）：v1 七个批导出不动、新增可选标量导出
（`mf_op_scalar_abi_version` / `mf_op_eval`）、宿主侧 `{函数名 → 模块, 预算}` 注册表、逐调用 fuel、
`@ast.Value ↔ JSON` marshal、fail-closed 映射；§5 六条开放问题（编码/批量化/错误分类/注册表治理/
**参数类型**/与 mbel-in-guest 的关系）——参数类型一条由 P6 评估发现 #9 直接推出（mbel 体函数无类型声明，
沙箱形态应显式带类型）；§6 明确不做清单。README 决策 **28** 已记。P6 关账：全量 `scripts/gates.sh` 25 步绿。