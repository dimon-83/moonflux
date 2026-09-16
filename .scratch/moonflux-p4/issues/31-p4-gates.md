# 31 — P4 关账

**What to build:** 浏览器驱动的端到端门禁 + 文档 / 矩阵 / 决策记录同步。

**Blocked by:** 30.

**Status:** ready-for-agent

- [ ] `scripts/e2e-p4-editor.sh`：起 serve(--ws) + 内核 wasm-gc 制品 → 浏览器（headless）
      拖拽/编辑管道 → apply → run → 消费到预期记录；失败时保留页面截图与浏览器控制台日志
- [ ] README 决策记录（浏览器传输选型、编辑器渲染 spec 的实现边界、客户端内核化的分层）
- [ ] 兼容性矩阵：#11 读语义状态更新；如需新增条目按 §7 留痕
- [ ] AGENTS：P4 门禁状态 + §3 目录（新包）；tickets 27–31 关闭；全量回归
