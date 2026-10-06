# 101 — 门禁：e2e-p28-maintenance.sh

**What to build**：`scripts/e2e-p28-maintenance.sh`（chmod +x，注册进 gates.sh 非快块 → 步数 43→44）。腿：

1. **默认关**：无旋钮的 serve 下产键控超越版本，跨多个 housekeeping 周期后磁盘仍是全版本、stderr 无 compacted 行——重写不是默认。
2. **后台生效**：`MOONFLUX_COMPACT_MS=300` 重启 serve，等节拍后磁盘只剩每键最后版本、幸存偏移 = 原偏移（真偏移分帧），stderr 有逐段报告。
3. **组地板挡压实**：组在 offset N 提交 → floor 之下即使被超越也幸存；floor 之上压到 floor 内最后版本。
4. **手动命令不变**：无旋钮下 `cluster compact` 立即生效（阈值 0 语义）。
5. **spu leader**：sc+spu（spu 带旋钮）产数据经控制面，等节拍后 spu 磁盘被压实——节点路径同语义。
6. **维护期数据完好**：压实报告出现后继续 produce + consume，幸存记录逐字节一致（decode_log_frames.py）。

**Blocked by**：100。

**Status**：done（2026-10-06）

- [x] 脚本 + chmod + gates.sh 注册
- [x] 全腿绿


**落地实录**：三处门禁假设被实测修正——① 单次 produce = 一帧一段，滚动只发生在追加之间（P8「满了开下一段」），阈值 100 下两批并一段：数据拆 5 次生产才有封存段；② `wait_log` 只看在场不看增量，对 300ms 节拍是竞态：改有界计数等待；③ 断言采样与节拍交错会取到中途态：改有界**收敛**等待（收敛后幂等保稳）。`decode_log_frames.py` 升级为真偏移输出（列 1 = 帧基址 + 帧内位置；列 2 帧基址不变，p14 腿 9 回归通过）。
