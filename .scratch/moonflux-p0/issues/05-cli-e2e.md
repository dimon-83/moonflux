# 05 — 日志文件持久化 + CLI produce/consume + P0 端到端 demo

**What to build:** `moonflux` 单二进制（多子命令）跑通 P0 最小闭环：`serve`（单机阻塞 framed 会话服务，持有 topic 日志）、`produce --topic T --file F`（文件 Source：按行读入 → RecordBatch → 追加 topic 日志；`--remote host:port` 走会话协议）、`consume --topic T --from N`（本地读日志或 `--remote`，记录输出到 stdout）。日志段文件即协议字节流（复用 02 的帧格式 + 03 的恢复逻辑）。`scripts/e2e-p0.sh` 一键复现：种子文件 → produce → consume → diff 断言输出一致，即 P0 门禁"端到端 demo 可复现"。

**Blocked by:** 03, 04.

**Status:** done (2026-09-15)

- [x] `apps/cli` 可执行包（native），子命令解析（argparse 或手写薄解析）；`--data-dir` 默认 `./.moonflux-data`
- [x] 文件持久化 topic 日志：`data/topics/<t>/partition-0.log` + 写入前 CRC 批帧；重启后经恢复逻辑（03）继续追加（offset 续接）
- [x] framed 会话协议（magic+version+cmd+len）：ProduceBatch / FetchRequest / FetchResponse / Ok / Err；serve 为顺序单连接循环（P1 再做多路复用与并发）
- [x] consume 输出格式：每记录一行 `offset\ttimestamp\tkey\tvalue`（key 为空输出空串）；`--from` 支持从任意 offset 重放
- [x] `scripts/e2p-p0.sh`（命名 e2e-p0.sh）：生成确定性种子 → produce（本地与 remote 两种路径各跑一遍）→ consume → diff 断言；脚本可重复运行（幂等清理）
- [x] 集成测试（native）：内存注入句柄跑 append/read 往返（core 白盒已在 03 覆盖）；本 ticket 重点是 CLI 级集成与 E2E
