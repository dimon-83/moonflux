# 99 — 门禁与文档收口

**What to build**：

- `scripts/e2e-p27-editor-functions.sh`（chmod +x；与 p4-editor 同形）：`setup`（建内核 js、摆页面、serve --ws + 静态服务、打印 URL）· `bump`（CLI 把门禁集合更新到 revision 2——漂移腿的输入）· `verify`（断言数据不看像素）。**不进 gates.sh 步表**（浏览器阶段不可脚本按压，与 p4-editor 同一处置，注释留痕）。
- verify 断言（全部服务端事实）：
  1. `function-set list --remote` 有面板建的集合（面板 CREATE 经 WS 落地）；
  2. `topology.json` 的 spec 引用 `editor-fns` 且绑定 revision = 2（选择器 → spec → apply 的绑定链 + bump 后页面 re-apply）；
  3. consume 从 0 读回：旧记录按 **R2** 规则重现（`ALPHA?`）+ 新记录 `BETA?`——re-apply 换绑 + 「历史按当前规则重现」两个事实一次钉住；
  4. bump 后、re-apply 前的旧行为不变由 drive 阶段观察（P6 leg ⑥ 的既有断言不重复）。
- 文档同步：README 决策 52 + 能力表；AGENTS §2 P27 行 + P4 纪律块补一段；roadmap 三处；feature-matrix 行 ⏳→✅；progress-board 四道 + 快照日期；user-guide 编辑器节；tickets 关账；memory 更新。

**Blocked by**：97、98。

**Status**：done（2026-10-05）

- [x] 门禁脚本 + chmod
- [x] gates.sh 注释（不进步表的缘由）
- [x] 全循环实跑（本会话驱动浏览器阶段）
- [x] 文档九处 + memory


**落地实录**：verify 三腿全绿（面板 CREATE 经 WS、topology.json 绑定 revision 2 且 spec 携带引用、consume 从 0 得 `ALPHA?`+`BETA?` 且无 `!` 残留）。文档同步：README 决策 52 + 能力表两行陈旧修正（ABI v2 / 连接器 ⏳→✅，P26/P20 收口漏更）、AGENTS §2 P27 行 + P4 块、roadmap §1/§2/§3 + 头部快照、feature-matrix、progress-board 四道、user-guide §8、architecture。
