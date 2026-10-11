# P34 · 用户裁定的五项工程

**来源**：收官问答里"还需要完善"的清单，用户裁定顺序 **先 1 2，再 3 4 6**。

| # | 项 | 状态 |
| :--- | :--- | :--- |
| ① | **控制面 HA 与备份/恢复** | ✅ 2026-10-11（决策 74）：`cluster metadata show/backup/restore`（CRC-32C、修订不回退、`--force`、kind 检查）+ `sc --ha` 租约式 active/standby（epoch 围栏、standby 拒绝并指名 active、暂停后 STEPPED DOWN、standby 不扫存活）+ `scripts/e2e-p34-sc-ha.sh` **12 腿** |
| ② | **Linux 全量门禁 + macOS 真落盘** | ✅ **完成 2026-10-11**（决策 75）：`full-linux` job 已上线并**首次运行就抓到真问题**（11 个门禁用 `-f /dev/stdin` 喂 spec：macOS 的 bash 3.2 把 heredoc 做成临时文件，Linux 的 bash 5 做成管道 → `read_file` 先取 size 再 pread → 管道上失败 → 未加保护且 stdout 被丢弃 ⇒ `set -e` 让门禁**零输出死亡**）。12 处已改为真实 spec 文件 + `\|\| fail`，并加了静态护栏。**Linux 现状：53 passed / 0 failed**（p7 那条腿的根因与其它 11 个同一个：p7 用 here-string 把数据喂给 `produce --file /dev/stdin`，Linux 上分歧尾**根本没被创建**；改成真实文件后全绿）。`mf_fs_flush` 在 macOS 走 F_FULLFSYNC（回落 fsync），`moonflux doctor` 报告，p8 按平台断言（Linux 运行日志已出现 `the durability primitive is fsync on Linux, as the platform requires`）。**另修的竞态**：`e2e-p34-sc-ha.sh` 腿 10 曾只认"步下"（暂停的旧 active 恢复后"重新抢到租约"同样合法）——改为断言不变量（写入必须与租约一致、被拒的写入不得改元数据）并在失败时打印两侧日志。**CI 证据**：run `38149883678` 三腿全绿，Linux 日志含 `E2E-P7-PARTITIONS: all green`、`the durability primitive is fsync on Linux, as the platform requires`、`53 passed, 0 failed` |
| ③ | **metrics + 健康端点** | ✅ 2026-10-11（决策 76）：`--metrics-listen`（serve/sc）+ `/metrics` + `/healthz`（真读；standby 503/lease:failed）；门禁 `e2e-p35-metrics.sh` **10 腿**。**它抓到两个真 bug**：HA 租约临时文件同名（两 SC 共享目录时一方 ENOENT 退出）、metrics 端无换行请求**阻塞事件循环**；另修了我自己"把 WELCOME 计成 ERR_UNKNOWN_COMMAND"的计数错误 |
| — | **下一轮先做的两件** | ① p34 腿 10 去竞态（+ 失败时 dump 两侧日志）；② p7 分歧尾截断在 Linux 上的一腿 |
| ④ | **跨节点状态迁移与续算** | ✅ 2026-10-11（决策 77）：键控主题 + 进度标记 + `--state-remote`（一个分区一个写入者）+ `--resume`；`docs/state-migration.md`；门禁 `e2e-p36-state-migration.sh` **8 腿**。**键空间再均衡仍未立项**（如实标注） |
| ⑤ | **镜像/多区域 与 恰好一次/事务 的显式决策** | ✅ 2026-10-11（决策 78）：两条都写明"不做 + 理由 + 触发条件 + 现有替代"，`feature-matrix` 的裸 ⏳ 换成 ❌ 决策行 |

**纪律**（与 P30/P31 相同）：可证伪门禁（纳入 `gates.sh`）、文档同步、ticket、CI 两腿（现在含 Linux 全量）绿、不得假实现或静默降级。
