# 30 — Web 编辑器 v1（spec 的渲染器）

**What to build:** 一个静态页面（无框架、无构建步骤）+ 一个 wasm-gc 内核模块：页面**渲染**
PipelineSpec（拖拽 nodes 改拓扑），调用内核做 parse/validate/compile/plan-diff，再通过 WS 网关
apply / run / consume，把数据画出来。**编辑器永远渲染 spec，不反向定义规范**（决策 7）。

**Blocked by:** 29（传输）、28（客户端）、以及 core/spec + core/pipeline（已有）。

**Status:** ✅ done (2026-09-17)

- [x] wasm-gc 模块：导出 spec 校验 / 编译拓扑 / plan 差异（薄 ABI，纯内核函数）
- [x] 页面：spec 编辑（源/变换/汇 + topic）→ 实时校验错误展示 → plan 差异预览 →
      apply → run → consume 列表（记录滚动显示）
- [x] 浏览器端 WS 客户端复用 `core/client`
- [x] 门禁：**浏览器驱动**（headless）完成"改拓扑 → 校验通过 → apply → run → 消费到预期记录"

## 落地记录

- **形态**：`apps/editor-kernel`（内核侧，编译器目标 **js**）+ `web/editor/index.html`（静态页，
  无框架、无构建步骤）+ `serve --ws`（传输，T29）。分工：页面拥有像素与 socket，**内核拥有 spec、
  校验、拓扑与协议**——页面里没有第二份 spec 格式或帧协议实现（AGENTS §1 规则 7）。
- **为什么是 js 而不是 wasm-gc**：先用 wasm-gc 试过，但 wasm-gc 模块把 `Bytes`/`String` 表示为
  **自己 GC 堆里的引用类型**、不导出线性内存、也没有工具链生成的宿主胶水 ⇒ JS 无法构造这些值去调用
  （实测：导出签名是 `(param (ref $moonbit.string)) (result (ref $moonbit.bytes))`，且无 memory 导出）。
  `js` 目标是同一份内核在浏览器里的**原生调用约定**（`Bytes` ↔ `Uint8Array`、`String` ↔ JS string），
  故编辑器内核编译到 js；wasm-gc 的可编译性仍由四后端矩阵保持。导出用
  `link: { "js": { "exports": [...] } }`（库包不产出 js 制品，必须 is-main）。
- **ABI**：`mf_editor_{abi_version, build_spec, validate, session_reset, hello, apply, produce, fetch, feed}`
  —— 文档进/出用字符串，协议帧用 `Uint8Array`。`build_spec` 是"图 → spec"的唯一映射处（UI 形状不是
  spec 形状，改 UI 不会悄悄改格式）；`validate` 复用 `core/spec` + `core/pipeline`；`feed` 用
  `core/client` 的编解码解析应答。
- **协议补的一个动词**：`CMD_APPLY_PIPELINE=19` —— 浏览器要能"部署"，而 apply 原本只是 CLI 本地操作；
  服务端复用自己的静态检查（`compile_node`）+ 落盘，运行中的 serve 下一次请求就走热重载生效。
  跨线测试：好 spec → OK(name, processes)；坏规则 → ERR + mbel 静态检查原文。
- **三个真实缺陷（都是"看起来在跑"的反面）**：
  1. **`Int64` 在 js 后端是 `BigInt`**：页面传 `0`（number）进 `mf_editor_fetch` ⇒ 内核内
     `BigInt.asUintN` 抛 `TypeError` ⇒ 点击处理器整段中断，**日志只停在 "consuming…"，什么都看不见**。
     修：页面传 `0n`，并把所有动作与应答处理包进 `guard()`（异常进日志）——静默无响应的按钮是最坏结果。
  2. **调色板只改模型不重渲染**：`refresh()` 不调 `render()`，节点加进去泳道里不出现（快照里泳道全空）。
     修：`refresh()` 统一"重渲染 + 重派生 spec"，并顺带刷新按钮可用性（第二个 bug：图有效后按钮仍禁用）。
  3. **`serve` 一次只服务一个连接**（P1 遗留，早已记录）：浏览器的长连接会把 CLI 与其他客户端**饿死**。
     本门禁因此分两段：浏览器阶段（我驱动真实浏览器完成 compose→deploy→run→consume）与脚本断言阶段
     （先读**磁盘上的段文件**——段文件本身就是协议流，不需要连接；再在编辑器标签页关闭、连接槽释放后
     做 CLI 读取，验证变换链确实在消费路径上跑）。这条限制记入 P4 已知缺口，下一步是多路复用。
- **门禁**：`scripts/e2e-p4-editor.sh {setup|verify|all}` 4 条断言全绿（拓扑落盘 → 日志里是浏览器写进去的
  记录 → 部署的 expr 链确实执行（取回为大写）→ 端到端成立）。`tools/decode_log_frames.py` 直接解码段文件，
  使"数据侧"断言不依赖任何连接。
- 测试：编辑器内核由 node 冒烟验证（ABI/构建 spec/校验拓扑/坏图报错/帧字节），并作为页面资产随门禁打包。
