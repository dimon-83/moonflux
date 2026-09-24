# 82 — P20 spec 与接线

**What to build:** PipelineSpec 增 `KafkaSource(String)` / `KafkaSink(String)`；`kafka_url_ok`
校验（前缀 + 非空 host/topic + `?partition=` 为数字 + `?from=` 属 {earliest, latest, <数字>}）；
`pipeline run` 与 `core/pipeline` 的映射（含 sink detail）；unknown-type 文案更新。

**Blocked by:** 81。

**Status:** done (2026-09-23)

- [x] `core/spec`：两个变体 + 校验 + 解析臂 + 文案（supported 列表加 kafka）
- [x] `apps/cli/pipeline.mbt`：`KafkaSource(url)` / `KafkaSink(url)` 构造
- [x] `core/pipeline`：source/sink detail（`kafka 源/汇: url`）
- [x] spec wbtest：正例（源+汇）、缺 topic、非法 partition、未知类型例仍是 `amqp`
- [x] **回归提醒**：语料/单测里凡把某个当前未知的类型名当「未知例子」的，本轮上线后不要再用
      `kafka`（P19 的 `mqtt` 教训）
