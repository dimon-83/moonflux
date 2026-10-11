# P34 · 用户裁定的五项工程

**来源**：收官问答里"还需要完善"的清单，用户裁定顺序 **先 1 2，再 3 4 6**。

| # | 项 | 状态 |
| :--- | :--- | :--- |
| ① | **控制面 HA 与备份/恢复** | ✅ 2026-10-11（决策 74）：`cluster metadata show/backup/restore`（CRC-32C、修订不回退、`--force`、kind 检查）+ `sc --ha` 租约式 active/standby（epoch 围栏、standby 拒绝并指名 active、暂停后 STEPPED DOWN、standby 不扫存活）+ `scripts/e2e-p34-sc-ha.sh` **12 腿** |
| ② | **Linux 全量门禁 + macOS 真落盘** | 🔶 **进行中**（决策 75）：`full-linux` job 已上线并**首次运行就抓到真问题**（11 个门禁用 `-f /dev/stdin` 喂 spec：macOS 的 bash 3.2 把 heredoc 做成临时文件，Linux 的 bash 5 做成管道 → `read_file` 先取 size 再 pread → 管道上失败 → 未加保护且 stdout 被丢弃 ⇒ `set -e` 让门禁**零输出死亡**）。12 处已改为真实 spec 文件 + `\|\| fail`，并加了静态护栏。**Linux 现状：51 passed / 1 failed**——只剩 `e2e-p7-partitions.sh` 的"分歧尾截断被报告"一腿。`mf_fs_flush` 在 macOS 走 F_FULLFSYNC（回落 fsync），`moonflux doctor` 报告，p8 按平台断言（Linux 运行日志已出现 `the durability primitive is fsync on Linux, as the platform requires`）。**另需修**：macOS full 上 `e2e-p34-sc-ha.sh` 腿 10 在 CI 上是竞态（暂停的旧 active 恢复后"重新抢到租约"与"步下"都合法，门禁只认后者）——改成断言不变量（不持租约时不得写入 + 元数据不变）并在失败时打印两侧日志 |
| ③ | **metrics + 健康端点** | ⏳ 待做 |
| — | **下一轮先做的两件** | ① p34 腿 10 去竞态（+ 失败时 dump 两侧日志）；② p7 分歧尾截断在 Linux 上的一腿 |
| ④ | **跨节点状态迁移/再均衡** | ⏳ 待做 |
| ⑤ | **镜像/多区域 与 恰好一次/事务 的显式决策** | ⏳ 待做 |

**纪律**（与 P30/P31 相同）：可证伪门禁（纳入 `gates.sh`）、文档同步、ticket、CI 两腿（现在含 Linux 全量）绿、不得假实现或静默降级。
