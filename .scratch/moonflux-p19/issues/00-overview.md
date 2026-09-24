# 00 — P19 里程碑概览（连接器流式语义 + MQTT）

**门禁（可证伪）**：`scripts/e2e-p19-mqtt.sh` 全绿——Python 迷你 broker（独立第二实现，同
`mfs_probe.py` 的精神）作对端：源侧订阅后收到 3 条消息全部落 topic 且出 sink；汇侧发布的消息
被 broker 完整收到；CONNECT/SUBSCRIBE 的形状被 broker 断言；坏地址/拒绝连接是结构化错误；
一次性源（file/stdin/http）行为**逐字节不变**（流式改造不改变既有语义）。

**前置事实（本轮实测，设计据此）**
- `pipeline run` 是严格一次性：一次 `pull()` → append → transform → sink → `cli_exit(0)`——
  订阅型源（MQTT）装不进去（拉一次就退出）；`Source.pull` 的返回类型也没有「此刻没数据」
  与「源已耗尽」的区别，而 file 源每次 pull 都重读整文件——不做三态就会有两种错法：
  流式源被当成耗尽、一次性源被反复重放。
- 连接器框架已留位（P1）：`Source{name, pull}` / `Sink{name, flush}` + spec 的
  `source/sink` 类型化 JSON（`{"type": ...}`）+ `pipeline run` 的 spec→构造器映射；
  MQTT 的接线点全在这三处。
- MQTT 3.1.1 协议面可控（固定头 + 剩余长度 varint + 十余种控制包），可零依赖手写；
  Kafka 的协议面（ApiVersions/Metadata/Produce/Fetch/RecordBatch v2/压缩编解码）远大于此，
  **单独立票排后**（本里程碑不做）。

**范围裁剪**：MQTT 首版**订阅/发布均 QoS 0**（订阅 QoS 0 时 broker 按 min 降级送出，入站
只需处理 QoS 0 的 PUBLISH；出站 QoS 1 要 packet id 与 PUBACK 等待，列后续候选）；
不做 TLS over MQTT（本地/内网形态；`@net` 的 TLS 是可选后续）、不做遗嘱/保留消息/自动重连
（断线即错误，重试是调用者的事——与"失败 = 下一个 tick 重试"的既有纪律一致）；Kafka 不立项。

**Tickets（依赖序）**
- 78 连接器框架三态 pull（`Records` / `Quiet` / `Exhausted`）+ run 循环（一次性源语义不变）
  ——无阻塞
- 79 MQTT 3.1.1 客户端 + `mqtt_source`/`mqtt_sink` + spec 变体与接线——阻塞于 78
- 80 门禁（Python 迷你 broker + `e2e-p19-mqtt.sh`）与文档——阻塞于 79

**状态**：达成（2026-09-23，`e2e-p19-mqtt.sh` 5 腿全绿、全量 36/36；README 决策 43；矩阵 #23）。
