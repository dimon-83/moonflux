# 30 — Web 编辑器 v1（spec 的渲染器）

**What to build:** 一个静态页面（无框架、无构建步骤）+ 一个 wasm-gc 内核模块：页面**渲染**
PipelineSpec（拖拽 nodes 改拓扑），调用内核做 parse/validate/compile/plan-diff，再通过 WS 网关
apply / run / consume，把数据画出来。**编辑器永远渲染 spec，不反向定义规范**（决策 7）。

**Blocked by:** 29（传输）、28（客户端）、以及 core/spec + core/pipeline（已有）。

**Status:** ready-for-agent

- [ ] wasm-gc 模块：导出 spec 校验 / 编译拓扑 / plan 差异（薄 ABI，纯内核函数）
- [ ] 页面：spec 编辑（源/变换/汇 + topic）→ 实时校验错误展示 → plan 差异预览 →
      apply → run → consume 列表（记录滚动显示）
- [ ] 浏览器端 WS 客户端复用 `core/client`
- [ ] 门禁：**浏览器驱动**（headless）完成"改拓扑 → 校验通过 → apply → run → 消费到预期记录"
