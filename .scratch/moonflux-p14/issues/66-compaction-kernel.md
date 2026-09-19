# 66 — 压实内核：空洞容忍的读取 + 批粒度压实

**What to build:** `core/log` 两件事。其一，**读取路径改为信任 `batch.base_offset` 并容忍帧间
空洞**（压实后的日志不再逐帧连续）；其二，`SegmentedLog::apply_compaction(floor, ...)`：对每个
「段末 ≤ floor」的段，以**提交前缀 [0, floor) 内的每键最新偏移**做决策，删掉所有非最新记录，存活
记录按**最长连续偏移段**重新成帧（帧基址 = 首条存活记录的原始偏移）。整段无删除 → 段文件不动。

**Blocked by:** 65（键要有真实值才可测）。

**Status:** done (2026-09-18)

- [x] 读取信任 base_offset：`read` / `read_raw` / `rebuild_index_static` / `rebuild_index` /
      `segment_summaries` / `truncate_to_boundary`（+ 计数辅助）；空洞下语义：`read(from)` 返回
      偏移 ≥ from 的记录，`read_raw(from)` 从**首个 base ≥ from 的帧**开始，`from` 落在空洞里
      不再是错误；`append_raw` 保持尾部严格连续
- [x] `skip_to(offset)`：仅向前推进 `next_offset`（跟随者追上被压实的 leader 时的空洞跳跃），
      带报告位；`append_raw` 语义不变
- [x] `apply_compaction(floor, now_ms, policy) -> Result[CompactionReport, LogError]`：
      策略 = `{ max_bytes, max_age_ms }`（与 retention 同形；0 = 关闭）；报告 =
      `{ rewritten : Array[SegmentCompaction { base, frames_before, frames_after, dropped_records,
      bytes_before, bytes_after }] }`；只动「段末 ≤ floor」的封存段，幂等（第二遍空报告）
- [x] 等键：空键记录**永不**被淘汰；同键取最大偏移
- [x] 确定性证据：同一日志两次压实字节一致；`moon test` 双后端
- [x] wbtests：空洞读（read / read_raw / 索引回退一致）、压实保留偏移、floor 之上不动、
      空键保留、幂等、`skip_to` 与 append_raw 的边界、压实后 torn tail 恢复仍干净
