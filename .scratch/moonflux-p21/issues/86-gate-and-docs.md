# 86 — P21 门禁与文档

**What to build:** `e2e-p12-security.sh` 新增腿 8–10；全部文档同步。

**Blocked by:** 85。

**Status:** in progress (2026-09-25)

- [ ] 腿 8（ACL 双向）：bob（read-write）仅授权 orders 的读写 → 对 events 的 produce/fetch
      被拒（码 10、消息含主题与用户名）；对 orders 的 produce/fetch 放行
- [ ] 腿 9（回归 + 收窄）：无 grants 的凭据行为与 P12 完全一致；read-only + write grant 仍不可写
      （角色表先行）
- [ ] 腿 10（审计）：拒绝与认证失败在 audit.log 里有 JSON 行（user/cmd/topic/decision 齐全），
      **审计文件里 grep 不到任何 token**（沿用 P12 的凭据 grep 纪律）
- [ ] 文档：AGENTS §2 P21 行 + 安全面纪律块补「角色先行、授权收窄」「审计记什么不记什么」；
      README 决策 45；feature-matrix 安全面行；compatibility-matrix #25（对标 Fluvio 三级策略
      的诚实比较：实例级 + 审计 = 超出对标）；user-guide §6 安全面（auth.json grants 示例）；
      progress-board 四道；生产就绪度评估复核（§3.4 合规面解除后的结论更新）
- [ ] `scripts/gates.sh` 全量回归（37 步）通过

**腿 7 抖动的根因（2026-09-25，追了三轮）**：不是数据路径 bug，是**门禁自己的 awk 假阳性**。
`count_settled` 解析 `cluster status` 时把 `hw=? leo=? (leader unreachable)` 也当成了
settled——awk 对 `"?"` 与 `"2"` 做**字符串**比较，`"?" > "2"` 成立。失效链条：腿 6 的 TLS
探针风暴 + 三分区同时采纳的负载波峰下，spu-b 对 spu-a 的同步链接拨号（握手期限仅
1000 ms，`synclink.mbt` HANDSHAKE_TIMEOUT_MS）反复超时重试，p0 的链接在门禁比对时尚未
打开；同一时刻 SETTLED 轮询里对 spu-a 的 OFFSET_INFO 查询超时，状态行写 `hw=?`，awk 把
它数进 settled → **假通过** → 立刻字节比对 → p0 空段 → FAIL。p3/p7 不受影响：它们走
`cluster offsets` 单分区查询 + shell 精确数值比较（`[ "$HW" = "3" ]`），`?` 过不了。
修法：awk 只认 `hw=[0-9]+`（数值行才参与计数）。教训入 AGENTS P13 纪律面：**门禁的
解析器也是不可信输入的解析器**——`?` 这类哨兵值必须在解析处显式拒绝，而不是碰巧比较成立。
