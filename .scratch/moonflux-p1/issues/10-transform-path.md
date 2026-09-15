# 10 — transforms 接入数据路径 + 规则热重载

**What to build:** spec.transforms 真正执行：serve 的 fetch 路径按已应用 pipeline 的 transform 链逐条变换记录；`pipeline run` 同样执行（移除 mbel-p1 拒绝）。规则热重载：serve 轮询 topology.json 变更，秒级换入新编译的规则（compile-once），新 spec 非法时保留旧规则并警告。门禁「改规则秒级生效」的可证伪脚本。

**Blocked by:** 09.

**Status:** ready-for-agent

- [ ] serve 启动时从 applied topology.json 编译 transform 链（09 的执行件）；fetch 回放路径应用
- [ ] 热重载：轮询 topology.json（~1s 粒度），变更→重新 parse+compile→原子换入；非法 spec→保留旧规则+警告
- [ ] `pipeline run` 执行 transform 链（移除 mbel-p1 拒绝分支，core/pipeline 标记保留但 run 改为执行）
- [ ] `scripts/e2e-p1-rules.sh`：apply(upper) → produce → consume 显示转换 → 改 spec → apply（不重启 serve）→ consume 显示新输出 → diff 断言
- [ ] 集成测试：重载失败保留旧规则；transform 链顺序执行
