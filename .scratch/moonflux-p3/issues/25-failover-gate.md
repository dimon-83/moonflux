# 25 — 故障注入门禁脚本（P3 门禁本体）

**What to build:** `scripts/e2e-p3-failover.sh`：把概览里的四条断言变成可复现的脚本，
全部用真实多进程 + 真实故障（kill）验证，不 mock。

**Blocked by:** 22、23、24。

**Status:** ready-for-agent

- [ ] 断言 1：kill follower → leader 的 HW 停在原处（LEO 继续增长），窗口 ≥ N 秒采样确认
- [ ] 断言 2：follower 重启 → 追平（LEO 相等）→ HW 恢复推进；副本文件是 leader 前缀的字节级副本
- [ ] 断言 3：kill leader → SC 提名 → 新 leader 产生 → produce + consume 成功（读 Committed 模式）
- [ ] 断言 4：旧 leader 回归 → 自降 follower → 最终各副本 LEO/HW 关系一致；数据无丢失
      （记录数守恒：produce 过的记录在最终 leader 上全部可见）
- [ ] 脚本纳入 `scripts/gates.sh`（慢门禁组）
