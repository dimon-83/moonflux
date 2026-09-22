# 74 — P17 门禁与文档

**What to build:** `scripts/e2e-p17-bench.sh`（6 腿）进 `gates.sh`（34 → 35 步）；文档全量同步；
首版基线数字记录在案（含机器上下文）。

**Blocked by:** 73。

**Status:** done (2026-09-22)

- [x] 腿 1（produce 远端）：`records=20000 base_offset=0 end_offset=20000 batches=40`、
      `bytes=5120000`、延迟行 count=40 且单调；服务端存活
- [x] 腿 2（consume 远端 + --verify）：`records=20000 bytes=5120000 sequence_ok=true`、
      scan_end 推进到 20000
- [x] 腿 3（本地往返）：produce + consume --verify 于 `--data-dir`，同一组断言
- [x] 腿 4（latency 远端）：`samples=30 produced=30 consumed=30 sequence_ok=true`，两组
      直方图单调且 e2e p50 ≥ produce-ack p50
- [x] 腿 5（P16 回归护栏）：服务端 `opened` 行每主题恰好一条
- [x] 腿 6（负例）：`--record-size 5000000` 按名拒绝（退出非零），随后 10 条 produce 成功
- [x] `scripts/gates.sh` 计入（34 → 35）；五处步数口径同步（AGENTS §2 / feature-matrix /
      user-guide ×2 / architecture / roadmap）
- [x] 文档：AGENTS §2 P17 行 + P17 纪律块 + P13 块补「等待要等在 poll 上」一条；
      feature-matrix ⏳→✅；user-guide 基准段 + 脚本索引；cli-roadmap §3.3.3 回填；
      roadmap 阶段行 + 台账 + 划掉「P16 后续 ①」；compatibility-matrix #22；
      README 决策 41（报告与门禁分离）
- [x] `scripts/gates.sh` 全量回归 **35/35 绿**（p8/p14 竞态修复后重跑确认）

**首版基线（2026-09-22，Apple Silicon / darwin 25.4.0 arm64，debug 构建，
`_build/native/debug` 的 `cli.exe`，本地铁环回）**——数字是**报告**，供对照，不是门禁：

| 场景 | 修 ticket 75 前 | 修后 |
| :--- | :--- | :--- |
| produce 远端（20 000 × 256 B，批 512） | 2,372 recs/s；批 ack p50 **205 ms**（恒定，与载荷无关） | **116,271 recs/s**（29.8 MB/s）；批 ack p50 **3.97 ms** / p99 6.9 ms |
| consume 远端（同主题抽干） | 13,088 recs/s | **59,572 recs/s**（15.3 MB/s） |
| latency 远端（30 × 256 B） | ack p50 202 ms；e2e p50 **404 ms**（= 2 × 202） | ack p50 **107 µs** / p99 191 µs；e2e p50 **189 µs** / p99 279 µs |
| produce 本地（5 000 × 256 B） | 248,188 recs/s | 同（本地不经网络） |
| consume 本地 | 511,404 recs/s（131 MB/s） | 同 |
