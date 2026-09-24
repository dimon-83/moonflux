# 80 — P19 门禁与文档

**What to build:** `scripts/mqtt_test_broker.py`（Python 迷你 MQTT broker，独立第二实现——
同 `mfs_probe.py` 的精神：断言针对**线上字节**而非自家客户端的意愿）；`scripts/e2e-p19-mqtt.sh`
进 `gates.sh`（35 → 36 步）；全部文档同步。

**Blocked by:** 79。

**Status:** done (2026-09-23)

- [x] 迷你 broker（`scripts/mqtt_test_broker.py`，stdlib、按规范说话、线程/连接）：CONNECT→CONNACK
      （记录 client id / clean / keepalive / user）、SUBSCRIBE→SUBACK 并投递 `--publish`、
      接收 PUBLISH（写 received 文件）、PINGREQ→PINGRESP、`--refuse` 分支
- [x] 腿 1：订阅源流式交付 alpha/beta/gamma（topic 与 stdout 双断言）且**进程仍活着**
- [x] 腿 2：线上形状（`connect client_id=moonflux-source-… clean=1`、`subscribe topic=sensors`）
- [x] 腿 3：file 源 + mqtt 汇 → broker 收到两条并解码 topic
- [x] 腿 4：坏 url **apply 期**拒绝且说明形状；死 broker 结构化错误且报 connect
- [x] 腿 5：一次性源一遍退出（P19 循环不改既有语义）
- [x] `scripts/gates.sh` 计入（35 → 36 步）；步数口径同步（architecture/feature-matrix/
      user-guide ×1/roadmap/看板/评估）
- [x] 文档：AGENTS §2 P19 行 + **P19 连接器纪律块**（三态契约/会话复用/每批 flush/QoS 0 边界/
      门禁对端是独立实现）、feature-matrix 连接器行、user-guide MQTT 段 + 脚本索引、
      cli-roadmap §3.3.5、roadmap 阶段行 + 台账 + 待办拆分（MQTT 达成、Kafka 余项）、看板
      （已完成/待办/功能点/返工 #8）、compatibility-matrix #23、生产就绪度评估刷新、
      README 决策 43
- [x] `scripts/gates.sh` 全量回归（36 步）通过
