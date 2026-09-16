# 25 — 故障注入门禁脚本（P3 门禁本体）

**What to build:** `scripts/e2e-p3-failover.sh`：把概览里的四条断言变成可复现的脚本，
全部用真实多进程 + 真实故障（kill）验证，不 mock。

**Blocked by:** 22、23、24。

**Status:** ✅ done (2026-09-16)

- [x] 断言 1：kill follower → leader 的 HW 停在原处（LEO 继续增长），窗口 ≥ N 秒采样确认
- [x] 断言 2：follower 重启 → 追平（LEO 相等）→ HW 恢复推进；副本文件是 leader 前缀的字节级副本
- [x] 断言 3：kill leader → SC 提名 → 新 leader 产生 → produce + consume 成功（读 Committed 模式）
- [x] 断言 4：旧 leader 回归 → 自降 follower → 最终各副本 LEO/HW 关系一致；数据无丢失
      （记录数守恒：produce 过的记录在最终 leader 上全部可见）
- [x] 脚本纳入 `scripts/gates.sh`（慢门禁组）

## 落地记录

门禁不是单个脚本，而是四个脚本 + 一条命令（`scripts/gates.sh`，全 19 步）。概览里那四条断言
到具体脚本断言的映射如下（可逐条复跑）：

| 概览断言 | 实现脚本 | 具体断言 |
| :--- | :--- | :--- |
| 1. HW 只在副本确认后推进 | `e2e-p3-replication.sh` | 「with the follower down: HW stayed at 3 while LEO grew to 5」 |
| 2. 恢复即追平（副本是 leader 前缀的字节副本） | `e2e-p3-replication.sh` | 字节前缀断言 + 「the restarted follower caught up byte for byte」+ 分歧尾巴截断并报告 |
| 3. 选主 | `e2e-p3-failover.sh` | 「the silent leader was replaced: the survivor was offered the partition and promoted itself」+「the new leader serves writes and reads」 |
| 4. 旧 leader 回归自降 + 水位一致 | `e2e-p3-failover.sh` | 「self-demoted to follower (without being told)」+ 字节级追平 + 「hw covers both replicas again」 |

额外（超出概览的故障注入，都是"看起来能跑"的反例）：
- **硬杀**：`kill -9` 后新 leader 从磁盘恢复并**记录数守恒**（6 条全可读）——恢复语义（撕裂尾
  截断）与复制语义联合门禁；
- **无确认则无 leader**：所有副本沉默时 SC 会继续报价，但没有任何选举被记账（fail-closed）；
- **重启不是再平衡**（`e2e-p3-metadata.sh`）：SC 重启后声明与 placement 逐字节不变；
- **节点生命周期**（`e2e-p3-nodes.sh`）：注册 / 身份持久化 / 离线仅报一次 / 数据面不受控制面影响。
