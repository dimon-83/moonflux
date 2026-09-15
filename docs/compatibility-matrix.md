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
| 8 | **提交原子性**：单批写入要么整体可见要么整体消失 | produce 批原子追加 | 单帧单 write + 尾部恢复 ⇒ 追加原子；多进程并发写未加锁（P0 单写者假设） | ⚠️ 部分（单写者下成立；并发写属 P1/P3） | `core/log_test`（recovery）；限制记录于 `core/log/log.mbt` 文档 |
| 9 | **生产确认**：broker 回执分配的 base offset | produce 应答携带 offset | `serve` 逐连接应答 OK(base, count)；producer 打印分配区间 | ✅ 对拍通过 | `scripts/e2e-p0.sh`（offsets 0..5 / 5..10） |
| 10 | **多分区 / 段滚动 / 索引 / retention** | 分区与段管理（P3 范围） | v1 仅单分区单段，读为全扫（无索引） | ⏳ 未验证（P3 里程碑） | `core/log/log.mbt` 顶部范围说明 |
| 11 | **消费组 / 提交语义 / leader epoch / 未提交读开关** | Fluvio 消费组缺失等事实先行核查（报告 1.2/2.x） | 完全未实现；设计上无隐式消费组 | ⏳ 未验证（P3 里程碑） | — |
| 13 | **协议服务化**：版本协商握手 + 请求应答 + 错误码 | 线协议版本化（评估报告 1.2） | 帧 v2（MFS+版本 2+cmd+请求 id）；HELLO/WELCOME 主版本门；错误帧稳定码；旧版本对端收到结构化拒绝 | ✅ 对拍通过 | `apps/client` 单测（version sniffing / rid echo）+ `scripts/e2e-p0.sh` 远程路径 |
| 12 | **SmartModule 算子沙箱语义** | core-wasm ABI + 预算治理（报告 3.6/5.x） | 未实现（P2）；内核全后端可编译纪律已由双后端测试矩阵保持 | ⏳ 未验证（P2 里程碑） | CI 矩阵（`moon test --target native` / `--target wasm-gc`） |

**图例**：✅ 对拍通过（有可复现脚本/测试）｜⚠️ 部分验证（注明缺口）｜⏳ 未验证（属后续里程碑门禁）。

**维护规则**：新增对标语义先入表（状态 ⏳），落地并取得可证伪证据后更新为 ✅ 并附证据入口；状态变更需在 PR 说明中注明依据（AGENTS.md §7）。
