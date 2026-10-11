# P34 · 用户裁定的五项工程

**来源**：收官问答里"还需要完善"的清单，用户裁定顺序 **先 1 2，再 3 4 6**。

| # | 项 | 状态 |
| :--- | :--- | :--- |
| ① | **控制面 HA 与备份/恢复** | ✅ 2026-10-11（决策 74）：`cluster metadata show/backup/restore`（CRC-32C、修订不回退、`--force`、kind 检查）+ `sc --ha` 租约式 active/standby（epoch 围栏、standby 拒绝并指名 active、暂停后 STEPPED DOWN、standby 不扫存活）+ `scripts/e2e-p34-sc-ha.sh` **12 腿** |
| ② | **Linux 全量门禁 + macOS 真落盘** | ✅ 2026-10-11（决策 75）：CI 新增 `full-linux` job（ubuntu 上跑完整套件）；`mf_fs_flush` 在 macOS 走 **F_FULLFSYNC**（ENOTSUP/EINVAL 回落 fsync），`moonflux doctor` 报告所用原语，`e2e-p8-storage.sh` 按平台断言（Darwin→F_FULLFSYNC，Linux→fsync） |
| ③ | **metrics + 健康端点** | ⏳ 待做 |
| ④ | **跨节点状态迁移/再均衡** | ⏳ 待做 |
| ⑤ | **镜像/多区域 与 恰好一次/事务 的显式决策** | ⏳ 待做 |

**纪律**（与 P30/P31 相同）：可证伪门禁（纳入 `gates.sh`）、文档同步、ticket、CI 两腿（现在含 Linux 全量）绿、不得假实现或静默降级。
