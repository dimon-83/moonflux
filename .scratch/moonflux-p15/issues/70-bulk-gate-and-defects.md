# 70 — P15 门禁与暴露的缺陷

**What to build:** `scripts/e2e-p15-bulk.sh`（5 腿）进门禁；修掉门禁暴露的三处既有缺陷与一处门禁自身
的竞态。

**Blocked by:** 69。

**Status:** done (2026-09-19)

- [x] 腿 1：20 MiB 文件端到端（produce → consume）逐字节一致——远超旧的 8 MiB 双向上限
- [x] 腿 2：跨分块偏移精确（分批不产生偏移洞/重叠，一次发送报一个区间）
- [x] 腿 3：超限记录（单条 > 4 MiB）按名字拒绝且服务端存活
- [x] 腿 4：超限帧（批 > 16 MiB）被**结构化拒绝且有日志**、服务端存活（不再是服务端一行日志都没有的
      `connection reset`）
- [x] 腿 5：12 MiB 批次复制逐字节一致（两副本段文件 cmp）
- [x] 缺陷 1（客户端分片拼接覆盖）：`recv_exact` 每次 recv 都写回缓冲区起点，任何分片到达的应答被
      静默损坏（7 MiB fetch 报 `bad fetch reply` 的真因）；修为 `fill_exact`（追加到已收前缀之后），
      `apps/client/transport_wbtest.mbt` 用脚本化分片来源钉住
- [x] 缺陷 2（复制等待期泵空转）：`await_frame` 每读 8 KiB 泵一次、每次泵值一个 50 ms poll tick，
      大批次复制永远超不过 2s 对端期限；修为「先抽干 socket 再泵」
- [x] 缺陷 3（OpenSSL 错误队列粘滞）：垫片从不 `ERR_clear_error()`，一次失败握手之后
      `SSL_get_error` 把健康的 WANT_READ 报成 `SSL_ERROR_SSL`——安全门禁先故意试坏证书、紧接着的
      正常 produce 死在 13 字节帧头上；`SSL_ERROR_ZERO_RETURN` 改判干净关闭
- [x] 门禁竞态（p9）：`check_shares` 的输入取「最后两行」而非「每个成员的最新份额」——m2 先于 m1
      处理换代时 2/3 概率对行为正确的产品误红；改为全量行（`check_shares` 本就保留各成员最新份额）
- [x] `scripts/gates.sh` 计入（32 → 34 步，与 P16 的门禁同笔接线）
