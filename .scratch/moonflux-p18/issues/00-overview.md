# 00 — P18 里程碑概览（已定位小票收口：真偏移 + serve 命令面）

**门禁（可证伪）**：`e2e-p14-compaction.sh` 新增腿（压实后的远端/committed 消费显示**真偏移**；
本地消费跨洞不重复）；`e2e-p0.sh` 新增腿（serve 的 topic 家族 + group 结构化拒绝）。

**前置事实（本轮实测，设计据此）**
- **远端偏移在洞上撒谎**：压实留下的空洞（或规则过滤/扇出）使 `read_bounded` 返回真偏移的
  带洞条目，而 `frame_window` 把整个窗口重打包成**一个**帧（base = 首个产出记录的偏移）——
  客户端按 base+序号推导，空洞之后的记录全部错位。实测：幸存者 0,2,3，远端消费打印
  **0,1,2**。**compaction 今天就能触发**，不止规则；P14 门禁没抓到是因为它的偏移断言走本地
  路径。wire 格式与客户端解码（`decode_fetch_reply`/`decode_frames`）**早已逐帧按基址推导**——
  修法纯服务端。
- **本地消费跨洞重复**：`consume_local` 用**条数**推进游标（`next += entries.length()`），洞使
  条数 < 跨度 → 游标落回洞后 → 重复读（实测 2,3,2,3）。P17 的 `benchmark consume` 本地模式
  复制了同一错误。
- **serve 的 topic 命令缺失**：`topic create --remote <serve>` → `unknown command 15`。serve 已有
  元数据库（函数集同库），缺的只是命令接线；`topic delete` 会成为 P16 预言的**第二条写入路径**
  （删日志文件）——**失效机制必须先于它存在**（log cache 需要 evict API）。
- **serve 的 group 家族**：协调者是控制面（P9 纪律）；单机 serve 没有放置/世代，正确行为是
  **结构化拒绝并说明去哪找**（先例：数据节点对 CMD_LEADER 的 ERR_WRONG_ROLE 解释）。

**范围裁剪**：不做扇出的 e2e 腿（现有算子无 1→N 模式；扇出由 wbtest 钉住）；不做 serve 上的
完整 group 协调（需要放置/leader 地址发现，独立立项）；`.idx` 在压实后是否残留只做验证项
（P8 回退纪律保证正确性，fs replace 按设计应删）。

**Tickets（依赖序）**
- 76 真偏移：连续段重帧（ReplyPacker）+ 本地/基准游标按偏移推进——无阻塞
- 77 serve 命令面：topic 家族（create/list/delete + logcache evict + 删目录）+ group 结构化
  拒绝——阻塞于 76（同一轮文档）

**状态**：达成（2026-09-23，p14 腿 9–11 + p0 新腿 + wbtest 10 条全绿、全量 35/35；README 决策 42；矩阵 #20 证据更新）。
