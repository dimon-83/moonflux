# 09 — mbel transform 执行件（apps/transform）

**What to build:** 把 mbel 表达式引擎接成 moonflux 的动态规则执行件：编译期（apply/发布）静态检查表达式，运行期 compile-once + 每记录求值（Vm 模式缓存程序），budget 分级防失控。表达式上下文暴露记录字段（value/key/timestamp/headers_count），求值结果作为新的记录值。这是「改规则秒级生效」的执行地基。

**Blocked by:** None — can start immediately.

**Status:** done (2026-09-15)

- [x] 依赖接入：`moon add dimon-83/mbel`（registry 引用，不复制源码，AGENTS §8）；冒烟：compile→eval→再 eval（Vm 程序缓存）
- [x] `apps/transform`：`compile(expr) -> Result[Transform, String]`——语法/未知函数错误在发布期拦截（AGENTS §8 Compile mode 静态检查）
- [x] budget 分级常量（max_nodes/max_depth/max_steps，内部级固定档），求值超限→结构化错误，不 panic
- [x] `apply(t, record)`：构造 ObjectVal 上下文（value/key/timestamp/headers_count）→ 求值 → 仅接受 StrVal 结果作为新 value；非字符串/求值错误→结构化错误（fail-closed）
- [x] 单测：compile-once 复用、各 budget 触发、未知函数编译期失败、非字符串结果、空 header、多条记录连续求值
