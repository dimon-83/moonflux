# 76 — P18 真偏移：连续段重帧 + 游标按偏移推进

**What to build:** fetch 应答按**连续偏移段**分帧（一个段一帧，帧基址 = 段首记录的真偏移），
空洞与扇出各起新帧；本地消费与基准消费的游标按**最后一条的偏移 + 1** 推进（不再按条数）。

**定位证据（2026-09-23 实测）**：MOONFLUX_ROLL_BYTES=100 + serve，四条
`ka/kb/kc/kb`（唯一键/复发键/唯一键/复发键）→ 压实掉 `kb@1`（被 `kb@3` 取代）→ 段内中洞。
解码器证实幸存者 0,2,3；**远端消费打印 0,1,2**（单帧 base=0 + 序号推导）。本地消费同数据
打印 2,3,2,3（条数游标跨洞回退）。修法纯服务端：`decode_fetch_reply`/`decode_frames` 早已
逐帧按 `batch.base_offset` 推导；`encode_fetch_reply` 本就接受帧数组。

**Blocked by:** 无。

**Status:** done (2026-09-23)

- [x] `ReplyPacker`（apps/cli/serve.mbt）：`add(offset, record)` 连续则并入当前帧，空洞/扇出
      重复则封帧另起；`finish()` 收尾。未过滤未压实的窗口仍打包成单帧（与旧应答逐字节一致）
- [x] `frame_window` 改返回 `FramedWindow{frames, scan_end, base, records}`；三个分发位
      （fetch / fetch_partition / fetch_committed）接线；committed 的 `SyncResponse.base_offset`
      = 首帧基址、`record_count` = 产出记录数（spu 复用同一实现——`dispatch_fetch_partition`
      同包共享，改一处两边好）
- [x] `consume_local` 与 `benchmark consume`（本地）：`next = 末条.offset + 1`（实测旧游标在
      洞上打印 2,3,2,3）
- [x] wbtest（serve_wbtest.mbt 6 条）：连续→1 帧；中洞→2 帧且基址为真偏移；扇出重复→各自
      帧同基址；空→0 帧；断续续跑；首偏移上报——解码回验每帧 `base_offset`
- [x] e2e-p14 新腿 9–11：① 远端消费跨中洞显示真偏移（0,2,3）；② committed 读同真偏移
      （布尔 flag 故意放最前，兼测解析修复）；③ 本地消费零重复——修后 `e2e-p14` 全绿
- [x] 验证项（`.idx` 残留）：fs 的 `replace` 按设计删索引（`remove_file` 在位）；P8 回退纪律
      兜底，未发现正确性问题
- [x] **顺带发现并修掉**：`parse_flags` 无布尔 flag 概念——`--committed --remote X` 把
      `--remote` 当值吞掉，静默变成本地消费默认目录（CWD 冒出 `.moonflux-data`）；每个门禁
      都恰好把布尔 flag 写末尾才没炸。布尔集合（committed/follow/verify/ws/tls-require-client）
      不取值，`main_wbtest.mbt` 4 条钉住；committed 三路（远端/committed/本地）全验证
