# 37 — spec.functions 引用与编译链

**What to build:** spec 按名引用函数集；编译链先注册函数集再静态检查（unknown name 发布期拦截），
运行期按函数变换记录。

**Blocked by:** 36.

**Status:** done (2026-09-17)

- [x] `core/spec`：`$.spec.functions`（可选字符串 = 集合名），白名单补键
- [x] `apps/transform`：`compile_with(expr, functions)`（先 `add_expression_functions` 再
      `eval_expr_checked` 再编译）；`compile(expr)` 保持 = 空函数集。mbel 的 JSON→defs 解析入口
      优先复用（playground 有 `eval_with_functions(funcs_json,…)`），不公开则 apps 侧构造
- [x] `apps/cli/rules.mbt`：`compile_node` 按引用从本地 metadata store 解析；缺失/不可用 →
      apply 失败；函数集版本号随 topology 落盘（运维可见）
- [x] 语义决策：**函数集更新需 re-apply**（热重载版本戳是 topology.json mtime）——spec 是
      不可变部署，资产独立演进
- [x] 单测：自定义名通过静态检查（此前必失败转为通过）、缺失集拒绝、纯度拒绝、深递归被 mbel 预算拦截

### 关账（2026-09-17）

落地：`core/spec`（`ExprTransform(expr, functions)`，白名单补 `functions`，空串/非字符串分路径报错）、
`core/pipeline`（拓扑 brief 带集合名）、`apps/cli/rules.mbt`（`compile_node(store, t)` 解析集合 +
`resolved_function_sets` 收集去重排序）、`apps/cli/pipeline.mbt` 与 `apps/cli/serve.mbt`（apply 双重校验 +
`persist_applied(..., function_sets)` 把 revision 写进 `topology.json`）。

**与计划的差异（留痕）**：计划写 `$.spec.functions`（spec 级）；落地为
**表达式节点级** `$.spec.transforms[i].functions`——引用与使用它的表达式放在一起，避免一个全局键
悄悄作用于根本不调用它的节点；spec 级语义由"各节点写同一个名字"覆盖，无需第二套语法。

**语义**：集合更新不自动生效，re-apply 才换绑（revision 进拓扑，供核对漂移）；错误文本有界
（`MAX_ERROR_CHARS=512`）在本票一并落地（评估发现 #4）。