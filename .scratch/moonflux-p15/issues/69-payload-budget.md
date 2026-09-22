# 69 — P15 预算与数据路径

**What to build:** 让 `@protocol.MAX_BATCH_BYTES`（16 MiB）成为唯一真相，其余预算全部派生：
`MAX_RECORD_BYTES`（4 MiB，单条 key/value）；`PRODUCE_CHUNK_BYTES`（4 MiB，`Producer::send` 与本地
`produce` 同一套分批，偏移在到达序上连续，一次发送仍报一个区间）；`FETCH_WINDOW_BYTES`（读取窗口，
`read_bounded` / `read_raw_bounded` 按字节封顶且**至少一条/一帧**——让读者无法前进比让解码器拒绝更糟）；
`REPLICATION_WINDOW_BYTES`（1 MiB，tick 循环 + 2s 对端期限的推论）；hub 收发缓冲从协议派生，超限
**记日志再关连接**。fetch 应答带 `scan_end` 加法尾段（`encode_fetch_reply`）；`frame_window` 收拢
「规则后预算、基址锚定、扫描落点」；`batch_refusal` 让 `ValueTooLarge` 说清撞了哪条线。

**Blocked by:** 无。

**Status:** done (2026-09-19)

- [x] `core/protocol`：计量（`record_wire_size` / `FRAME_OVERHEAD_BYTES`）+ 上限常量 + 分批逻辑
      （`protocol_wbtest` 钉住计量与分批）
- [x] `core/log`：`read` / `read_raw` 拆出 `*_bounded`（预算 ≤ 0 = 无预算；首条/首帧必进）；
      `core/log_test` 两条有界读测试（预算截断、至少一条/一帧、连续窗口精确覆盖）
- [x] `serve`：三个 fetch 分发位换 `frame_window`——`base` = 首个**产出**记录的偏移（过滤窗口不再
      错位后续偏移），`scan_end` = 服务端扫描到的位置（规则全滤掉也推进，客户端不再把「这一窗满了」
      当「分区到头」）；超限批的拒绝带名字与修法
- [x] `consume` / `group`：游标按 `scan_end` 推进（组消费里规则全滤掉的窗口不再卡死成员）
- [x] `node`：SYNC_FETCH 应答走 `read_raw_bounded` + 1 MiB 窗口，跟随者下一轮要剩下的
- [x] `produce`：文件按 4 MiB 分批；单条超限在**生产者进程内**按名字拒绝（`record_size_violation`）
- [x] `hub`：缓冲从协议派生；一轮的读进 `pending` 每轮 join 一次（逐读整体复制会让收 17 MiB 变成
      19 GB memcpy）；超限记日志再断开
- [x] 客户端内核（`core/client` + `apps/client`）：分批发送、fetch 应答解出 `scan_end`
