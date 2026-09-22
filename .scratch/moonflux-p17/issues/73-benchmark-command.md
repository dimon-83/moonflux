# 73 — P17 benchmark 命令面

**What to build:** `cli.exe benchmark produce|consume|latency`（apps/cli/benchmark.mbt），三种模式
都支持本地（`--data-dir`）与远端（`--remote`）：

- **produce**：合成 N 条 × S 字节记录（值 = 4 字节大端序号 + 点填充，序号 = 记录偏移），按
  `--batch-records`（默认 512）分批逐批发送/追加并逐批计时（远端 = 一批一次 ack RTT，本地 = 一次
  append）。报告吞吐（records/s、bytes/s）+ 批延迟直方图（min/avg/p50/p90/p99/max，µs）。
  **偏移不连续 = 硬失败**（不是指标，是不变量）。批字节数必须 ≤ `PRODUCE_CHUNK_BYTES`
  （一次 send 恰一帧，计时才有意义）。
- **consume**：窗口抽干至 `scan_end`，报告吞吐 + 字节数 + 窗口数；`--verify` 校验每条值的序号头
  == 记录偏移，报告 `sequence_ok`。
- **latency**：N 轮「生产 1 条 → 消费至可见」，两条连接（producer + consumer），报告 produce-ack
  与 e2e 可见性两组直方图 + `sequence_ok`；起始偏移先探测 LEO，对任意 topic 状态成立。
- 计时：`cli_shim.c` 加 `mf_cli_now_us`（CLOCK_MONOTONIC 微秒）；直方图 = nearest-rank 整数
  纯函数（`percentile_rank`/`percentile_us`/`stats_line`），wbtest 钉住边界（n=1、p0/p100、
  空数组、序号头编解码往返）。
- 输出：stdout 是 `key=value` 指标行（门禁与基线文档可 grep），诊断走 stderr；单条超
  `MAX_RECORD_BYTES` 在本进程内按名字拒绝。

**Blocked by:** 无。

**Status:** done (2026-09-22)

- [x] produce/consume/latency 三模式，本地 + 远端（`apps/cli/benchmark.mbt`，约 620 行含注释）
- [x] 值 = 4 字节大端偏移头 + 点填充；`--verify` 消费侧校验，不匹配退出非零
- [x] 一批一帧硬约束（超 `PRODUCE_CHUNK_BYTES` 按名拒绝）；偏移不连续硬失败
- [x] `mf_cli_now_us`（CLOCK_MONOTONIC）进 `cli_shim.c`；nearest-rank 整数百分位
- [x] `main.mbt` 接线（usage / is_command / dispatch）
- [x] wbtest 5 条（rank 边界、单调、编解码往返、`bench_entry_ok` 三态）；
      **踩坑一枚**：MoonBit 的 `Bytes` 下标返回 `Byte`（8 位）而非 `Int`——`b << 16` 截回 8 位
      归零，头解析只剩末字节（1234567 解出 135 = 0x87）；先 `.to_int()` 再移位
- [x] `moon test --target native` 全绿（apps/cli 33/33）
