# 兼容性矩阵（对标语义验证状态）

> 规约依据：AGENTS.md §5——codec 与算子行为以 golden vectors 钉死，并维护本矩阵记录每个
> 对标语义的验证状态。对标系统为 Fluvio（设计参照，非依赖、非协议互通对象）；
> moonflux 线协议为自建（v1），"兼容"指**语义对齐**而非字节互通。

| # | 对标语义 | Fluvio 参照 | moonflux v1 现状 | 验证状态 | 证据入口 |
| :-- | :--- | :--- | :--- | :--- | :--- |
| 1 | **帧完整性与版本化**：帧头含 magic + 版本字节，未知版本拒绝 | 自研线协议版本化（评估报告 1.2） | `MFB` magic + version 0x01；未知版本 → `UnsupportedVersion` | ✅ 对拍通过 | `core/protocol/protocol_wbtest.mbt`（bad magic / unsupported version） |
| 2 | **记录批次载荷**：批量打包 + 逐记录 offset 语义 | RecordBatch（base offset + record count） | 批帧含 `base_offset` + `record_count`；log 顺序分配连续 offset | ✅ 对拍通过 | golden vectors（`core/protocol/testdata/`）+ `core/log_test/log_test.mbt` |
| 3 | **varint 编码**：长度字段紧凑编码 | Kafka 风格 varint/unsigned-varint（报告 1.2.4 参照） | ULEB128（10 字节上限），解码与 `moonbitlang/core` Buffer 编码器交叉对拍一致 | ✅ 对拍通过 | `core/codec_test/codec_test.mbt`（双实现一致性） |
| 4 | **损坏检测**：端到端校验和 | RecordBatch CRC | CRC32（IEEE）覆盖 count/len/records；base_offset 不入 CRC 以支持 broker 回填 offset | ✅ 对拍通过 | wbtest crc mismatch + `core/log_test`（corruption → `CorruptFrame`） |
| 5 | **恢复语义**：崩溃后截断撕裂尾，拒绝静默丢数据 | segment 恢复 + 校验（storage 不变量，参考工作规约） | 尾部半帧 → truncate 到最后完整帧；中部损坏 → 拒绝打开（`CorruptFrame`） | ✅ 对拍通过 | `core/log_test/log_test.mbt`（torn tail / mid-file corruption）+ fs-native 集成测试 |
| 6 | **消费重放**：从任意 offset 读取至多 N 条 | fetch 语义（offset + max bytes/records） | `read(from, max)` 窗口读取，LogEntry 带 offset；CLI `consume --from N` 重放 | ✅ 对拍通过 | `core/log_test`（windowed reads）+ `scripts/e2e-p0.sh`（--from 7） |
| 7 | **日志文件即协议流**：段文件可被协议解码器直接消费 | 段文件格式与线协议同源的设计取向 | 段文件 = 批帧串联；测试与 E2E 验证双可读 | ✅ 对拍通过 | `core/log_test/log_test.mbt`（segment-is-a-protocol-stream） |
| 8 | **提交原子性**：单批写入要么整体可见要么整体消失 | produce 批原子追加 | 单帧单 write + 尾部恢复 ⇒ 追加原子。**并发写的答案（P3）：每个分区同一时刻只有一个 leader**（由复制协议保证），节点内仍单进程串行——不是给段文件加多写者锁 | ⚠️ 部分（单 leader 下成立；多写者仍被设计排除） | `core/log_test`（recovery）+ `scripts/e2e-p3-failover.sh`（选举决定唯一 leader） |
| 9 | **生产确认**：broker 回执分配的 base offset | produce 应答携带 offset | `serve` 逐连接应答 OK(base, count)；producer 打印分配区间 | ✅ 对拍通过 | `scripts/e2e-p0.sh`（offsets 0..5 / 5..10） |
| 10 | **多分区 / 段滚动 / 索引 / retention** | 分区与段管理（P3 范围） | **控制面已有多分区模型**（`PartitionId{topic,index}`、placement、每分区 leader 与水位），但**存储仍是每主题单分区单段**（`<topic>/partition-0.log`）、读为全扫无索引；retention 未实现 | ⚠️ 部分（控制面就绪、存储未跟上） | `core/cluster`（分区/放置单测）+ `scripts/e2e-p3-metadata.sh`（声明→放置）；存储限制见 `core/log/log.mbt` |
| 11 | **消费组 / 提交语义 / leader epoch / 未提交读开关** | Fluvio 消费组缺失等事实先行核查（报告 1.2/2.x） | **读钳制已实现**：`ReadCommitted ≤ HW`、`ReadUncommitted ≤ LEO`（默认 Uncommitted），越界读结构化拒绝（`core/replica`，有单测），leader 对外暴露 `OffsetInfo`（`cluster offsets`）；**但尚未接入线协议 FETCH 应答**，故客户端还不能按模式读。消费组与托管偏移仍未实现（设计上无隐式消费组）；**leader epoch 数据面不存在——这是有意的，不是缺口** | ⚠️ 部分（语义与暴露就绪、客户端接线待做） | `core/replica_test`（读钳制/水位）+ `scripts/e2e-p3-replication.sh`（HW 语义） |
| 12 | **SmartModule 算子沙箱语义**：guest 算子经 ABI 在宿主数据路径执行，语义与原生实现一致 | core-wasm ABI + 预算治理（报告 3.6/5.x）：同一变换的 wasm 实现与内置实现必须等价 | ABI v1（7 个固定导出：abi_version / alloc_input / init / process / output_len / last_status / last_error）；in-process wasmtime，guest 无常驻状态；`upper` 与 identity 两组算子与 mbel 原生实现**字节级一致**；trap / 拒绝 / 死循环三类失败均 fail-closed（结构化错误、不吐半批、有界） | ✅ 对拍通过 | `scripts/crosscheck-operators.sh`（9 腿全绿）+ `adapters/wasmtime-native/wasmtime_wbtest.mbt`（6 项 in-process 集成） |
| 13 | **协议服务化**：版本协商握手 + 请求应答 + 错误码 | 线协议版本化（评估报告 1.2） | 帧 v2（MFS+版本 2+cmd+请求 id）；HELLO/WELCOME 主版本门；错误帧稳定码；旧版本对端收到结构化拒绝 | ✅ 对拍通过 | `apps/client` 单测（version sniffing / rid echo）+ `scripts/e2e-p0.sh` 远程路径 |
| 14 | **算子资源治理**：按信任层级限制单次调用的工作量 | SmartModule 预算/超时治理（报告 5.3/5.5） | tier（Internal/User/Tenant）双约束：记录数上限 + **指令数（fuel）**上限；fuel 为确定性计量（无时钟），超限报 `BudgetExceeded` 而非裸 trap；宿主墙钟超时未实现（adapter 目前不读时钟——留待需要时按 `call_timeout_hint_ms` 接入） | ⚠️ 部分（记录数 + fuel 已对拍；墙钟超时为声明的 hint，未接线） | `scripts/crosscheck-operators.sh`（spin 腿：0s 内被拦下）+ `core/operator/operator_wbtest.mbt`（tier 单调性） |

| 15 | **复制语义**：follower 拉取、副本进度、高水位 | follower-pull（SyncRequest 复用 fetch）+ LRS≈ISR + `HW=min(LEO)`（报告 §1.2.5/§1.2.6-B） | 副本主动 `SYNC_FETCH` 原样搬运帧（**字节副本**而非重编码）；`HW = 副本集合各 LEO 最小值`（含 leader 自身）、只前进不回退；LRS 按滞后阈值现算（落后失投票权、仍收记录、追上回归）；分歧按"新 leader LEO 唯一权威"截断并报告 | ✅ 对拍通过 | `scripts/e2e-p3-replication.sh`（字节前缀、HW 待确认、停机停滞、追平）+ `core/replica_test`（13 项语义） |
| 16 | **选主与故障转移**：集中提名 + 候选自我提升 + 旧 leader 自降 | SC 检测离线→挑最小滞后 follower→候选自我提升并确认；旧 leader 回归自降（报告 §1.2.6-B） | 提名是控制面的**状态**（随 leader 应答下发，SC 不拨号数据节点）；候选自己提升后 `CMD_CONFIRM` 回报，未获提名/被许给他人的提升一律拒绝；候选耗尽→分区无 leader（fail-closed）；旧 leader 回归**自降**并字节级追平 | ✅ 对拍通过 | `scripts/e2e-p3-failover.sh`（9 条断言，含 SIGSTOP 回归自降、kill -9 记录守恒、无确认则无 leader） |

**图例**：✅ 对拍通过（有可复现脚本/测试）｜⚠️ 部分验证（注明缺口）｜⏳ 未验证（属后续里程碑门禁）。

**维护规则**：新增对标语义先入表（状态 ⏳），落地并取得可证伪证据后更新为 ✅ 并附证据入口；状态变更需在 PR 说明中注明依据（AGENTS.md §7）。
