# 98 — 页面侧：函数集面板 + 编辑表单 + 选择器 + 漂移标记（web/editor）

**What to build**：页面拿到函数集的**渲染与对话状态**；一切构建仍调内核。

- **面板**（builder 列新 section）：表格（名称 / revision / 函数数 / 漂移标记），refresh 按钮，行内 delete 与「载入表单」；WELCOME 后自动 LIST，create/delete 成功后自动重 LIST。
- **编辑表单**：集合名 + 函数行（name / params 逗号分隔 / body / description，可增删）；「部署集合」走 `mf_editor_build_function_set` → `mf_editor_function_set_create`；服务端拒绝（mbel 校验/纯度）原样进日志。
- **表达式选择器**：expr 节点渲染集合下拉（— 无 — + 已知集合）；选择写入图节点（`functions`），由 build_spec 派生进 spec——页面不拼 spec。
- **漂移标记**：deploy 成功时对 spec 引用的集合快照 revision（`boundAtDeploy`）；LIST 发现 `当前 revision > 快照` → 行内标记 `↻ re-apply (applied r{旧} · now r{新})`；再部署即清除。标记是编辑器侧 advisory（说明文案注明；服务端真相 = topology.json）。
- **边界（议定范围第 5 项）**：面板提示「仅表达式函数集——不可信标量函数走 ABI v2 沙箱路径，此处不暴露」；页面无任何标量函数编写面。
- **对话状态**：`rid → 动作` 映射取代 FIFO shift（面板与流水线动作并发后，应答路由按 rid）；所有新动作过 `guard()`。
- **门禁钩子**：`window.moonfluxEditor` 增 `sets()` / `setForm(doc)` / `submitSet()` / `refreshSets()` / `pickFunctions(name)`。

**Blocked by**：97。

**Status**：done（2026-10-05）

- [x] 面板（列表/刷新/删除/载入）
- [x] 表单（构建走内核、错误透传）
- [x] expr 选择器（图 → build_spec）
- [x] 漂移标记 + deploy 快照
- [x] rid 路由 + guard + 门禁钩子
- [x] 边界提示（无标量函数面）


**落地实录**：真浏览器全循环走通（含漂移标记 `↻ re-apply (applied r1 · now r2)` 出现→重部署清除→历史按 r2 重现）。驱动环境事实：IAB 面板后台时指针事件（Playwright click / CUA 坐标）不交付，页面钩子 `window.moonfluxEditor` 与合成事件是为此设计的驱动面。另修一处 CSS（`#fn-form` 的 `display:grid` 压过 UA 的 `[hidden]`）。
