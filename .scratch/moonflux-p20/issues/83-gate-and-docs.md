# 83 — P20 门禁与文档

**What to build:** `scripts/kafka_test_broker.py`（stdlib 迷你 broker，锁定版本、录事实、
**校验我们批的 CRC-32C 并解析记录**、可 `--produce-version-max` 制造版本不兼容）；
`scripts/e2e-p20-kafka.sh` 进 `gates.sh`（36 → 37 步）；kafka-python 开发期对拍留痕；全部文档。

**Blocked by:** 82。

**Status:** done (2026-09-23)

- [x] 迷你 broker：ApiVersions v0（可声明支持的版本上限）、Metadata v1（单 topic 单分区、
      leader = 自身）、Produce v3（解析批：**CRC-32C 校验 + 记录解析**，分配 base offset，
      ack 带 base_offset）、ListOffsets v1（earliest=0 / latest=已存数）、Fetch v4（按 offset
      返还字节，批头 baseOffset 改写）、facts 文件
- [x] 腿 1（往返 + 键保全）：file 源（含 `--key-separator` 的键）→ kafka 汇 → broker 解析并
      校验 → kafka 源 → stdout 与 moonflux topic（键列）逐字节一致
- [x] 腿 2（线上形状）：broker 记录并断言 ApiVersions 探针、Metadata 的 topic、Produce 的
      acks=1 与批的 CRC/记录数
- [x] 腿 3（源边界）：`from=latest` 从末端开始；`?partition=N` 拒绝（broker 只有分区 0）→
      结构化错误
- [x] 腿 4（负例）：坏 url apply 期拒绝；死 broker 结构化错误；`--produce-version-max 2`
      的 broker → "broker does not support produce v3" 明确错误且进程退出
- [x] 腿 5（回归）：一次性源语义不变（file → stdout 一遍退出）
- [x] **开发期对拍（留痕，不进 gates）**：用 kafka-python 解析我们客户端产出的
      ProduceRequest/Fetch 请求字节与自建批，双方字段一致；命令与输出记入 ticket 与提交正文
  **对拍记录**（kafka-python 3.0.11，隔离安装 /tmp/kafkalib；broker 以 `--dump` 捕获原始请求帧后逐帧解码）：
  ```
  api_key=18 (api_versions) v0 corr=1 client=moonflux-kafka -> decoded OK
  api_key=3 (metadata)     v1 corr=2 client=moonflux-kafka -> decoded OK
  api_key=0 (produce)      v3 corr=3 client=moonflux-kafka -> decoded OK
      produce: topic=events partition=0 acks=1 transactional=None timeout=10000
      OUR batch parsed by kafka-python: base_offset=0 magic=2 records=[b'one', b'two']
  ```
  （decode 只吃 body——3.x 旧式类不再吃头；header 已手工剥离核对）
- [x] `scripts/gates.sh` 计入（37 步）+ 步数口径同步（AGENTS/architecture/feature-matrix/
      user-guide/roadmap/看板/评估）
- [x] 文档：AGENTS §2 P20 行 + Kafka 边界、"对接对象而非对标参考"的定位句；feature-matrix
      连接器行加 Kafka；user-guide Kafka 段（URL 形态、边界、最小测试 broker）；cli-roadmap
      回填；roadmap 阶段行 + 台账 + 待办 Kafka 行收口；看板四道更新；compatibility-matrix
      #24（对接生态对象，非对标面）；README 决策 44（Kafka 客户端的版本锁定与边界）；生产就绪
      度评估刷新（连接器行）
- [x] `scripts/gates.sh` 全量回归（37 步）通过
