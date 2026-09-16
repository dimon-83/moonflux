# 00 — P3 里程碑概览（复制 + 选主 + 元数据调和）

**门禁（可证伪）**：故障注入通过 —— 节点宕机 / 恢复后**水位一致性**成立。

具体化为四条断言（`scripts/e2e-p3-failover.sh`）：
1. **HW 只在副本确认后推进**：杀掉 follower，leader 的 HW 停住不再前进（LEO 仍可增长）；
2. **恢复即追平**：follower 重启后从 leader 拉取补齐，HW 恢复推进，副本文件与 leader 前缀字节级一致；
3. **选主**：杀掉 leader，SC 提名最小滞后 follower，该副本自我提升并确认，集群继续可 produce/consume；
4. **旧 leader 回归自降**：原 leader 重新加入后变 follower，行为收敛到与其它副本一致的 LEO/HW 关系。

**对标语义（事实先行，报告 §1.2.5 / §1.2.6；不得引入 Kafka/Raft 假设）**
- 复制是 **follower 拉取**（SyncRequest 复用 fetch 语义）——**不得反转成 leader push**；
- **LRS ≈ ISR**：滞后超阈值的副本移出 LRS（失去选举资格，但仍继续收记录），追上后自动回归；
- **HW = leader 上各副本 LEO 的最小值**（只前进、不回退）；对外暴露 `OffsetInfo{hw, leo}`：
  ReadCommitted ≤ HW，ReadUncommitted ≤ LEO，**默认 Uncommitted**；
- **数据面无 leader epoch**（epoch 只存在于元数据层）→ 不得引入 epoch 截断/任期假设；
- 选主：SC 检测离线 → 挑**最小滞后** follower → **候选自我提升并确认**（两段式）→ 候选耗尽则
  分区 Offline；旧 leader 回归**自降** follower；
- 元数据：SC 跑 **level-triggered 调和循环**，声明式 Spec 是期望状态，状态本地持久化
  （存储可插拔：本地优先，K8s CRD 属 P4）。

**本项目需显式定义的空白（参考系统未定义，我们定义并留痕）**
- **无 epoch 下的分歧处理**：新 leader 的 LEO 是唯一权威；回归副本本地 LEO 若超过 leader LEO，
  必须截断到 leader 的 LEO，并**把丢弃的字节/记录数写进恢复报告**（绝不静默）。→ README 决策。
- **并发写（矩阵 #8）的 P3 答案**：不是给段文件加多写者锁，而是**每个分区同一时刻只有一个
  leader**（由复制协议保证）；节点内写入仍是单进程串行。→ README 决策。

**Tickets（依赖序，编号全局连续）**
- 19 `core/cluster`：控制面数据模型 + level-triggered 调和（纯计算）
- 20 `core/replica`：复制语义（LEO/HW/LRS/OffsetInfo/读钳制）+ 副本角色状态机（纯计算）
- 21 节点形态：`spu` / `sc` 子命令 + 节点身份 + 心跳与注册（协议 v2 扩展）
- 22 follower-pull 复制数据路径（含受控截断 `truncate_to`，落地分歧处理规则）
- 23 选主与故障转移（SC 提名 + 两段式自我提升 + 旧 leader 自降 + Offline）
- 24 元数据存储（可插拔接口，本地后端）+ 调和驱动 placement
- 25 门禁脚本 `scripts/e2e-p3-failover.sh`（四条断言）
- 26 P3 关账：文档 / 决策记录 / 兼容性矩阵状态 / 全量回归

**范围裁剪**：不做 K8s CRD 后端（P4）；不做存量再平衡（对标系统也没有）；不做多副本并行读
（单 leader 读写）；消费组与提交语义（矩阵 #11）只做"读钳制开关"这一半，托管偏移留后续。

**状态（2026-09-16 全部关闭）**
- [x] 19 控制面模型 + 调和（`core/cluster`）
- [x] 20 复制语义与角色状态机（`core/replica`）
- [x] 21 节点形态 spu/sc + 心跳注册
- [x] 22 follower-pull 复制数据路径 + 受控截断
- [x] 23 选主与故障转移
- [x] 24 元数据存储 + topic/cluster 命令面
- [x] 25 故障注入门禁（断言映射见该 ticket）
- [x] 26 关账：文档 / 矩阵 / 回归

**门禁达成**：`scripts/gates.sh` 19 步全绿，其中 P3 四个脚本覆盖概览的四条断言，并额外覆盖
硬杀（kill -9）后记录数守恒、无确认则无 leader、重启不是再平衡、节点生命周期与身份持久化。
**与计划的两处偏离已留痕**：(1) 选主方向由"SC 主动提名调用"改为"SC 声明提名状态 + 候选自我
提升并确认"，原因是单线程进程互相调用会死锁（门禁中真实复现）；(2) `topics.json` 引导路径被
元数据 store 取代（声明唯一来源），两个早期门禁脚本相应改用 `topic create`。
