# 13 — P1 门禁验证 + 文档同步

**What to build:** 汇总验证两个 P1 门禁可证伪且可复现；文档同步（README/AGENTS 状态、决策记录）；全量回归不回退。

**Blocked by:** 10, 11, 12.

**Status:** done (2026-09-15)

- [x] 门禁 1 证据：e2e-p1-connectors.sh（file/stdin/http 三源 + stdout/http 双汇全绿）
- [x] 门禁 2 证据：e2e-p1-rules.sh（不重启 serve，改规则秒级生效）全绿
- [x] 回归：e2e-p0.sh、e2e-p0p.sh、crosscheck-protocol.sh 全绿；native+wasm-gc 测试通过；四后端矩阵不回退
- [x] README/AGENTS 状态更新 + P1 决策记录（transform 消费路径语义、热重载机制、SDK 连接抽象）
- [x] tickets 勾选关闭
