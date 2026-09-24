# 79 — P19 MQTT 3.1.1 客户端 + 连接器 + spec

**What to build:** 零依赖的 MQTT 3.1.1 客户端（`apps/connectors/mqtt.mbt`，跑在 `@net` 之上）：
CONNECT/CONNACK、SUBSCRIBE/SUBACK、PUBLISH（入站 QoS 0）、PINGREQ/PINGRESP、DISCONNECT；
固定头 + 剩余长度 varint 的编解码；`mqtt_source(url, timestamp)`（首次 pull 建连订阅，之后
按 socket 期限读消息，无消息返回 `Quiet`）与 `mqtt_sink(url)`（发布每条记录的值）；URL 形态
`mqtt://[user:pass@]host:port/topic`。spec 增 `{"type":"mqtt","url":...}`（源与汇；校验
前缀与 topic 非空）+ `pipeline run` 接线。

**边界（写进文档，不写 TODO）**：订阅与发布均 QoS 0（订阅 QoS 0 ⇒ broker 按 min 降级，入站
只需 QoS 0 处理）；不做 TLS/遗嘱/保留消息/自动重连（断线即结构化错误）；URL 内嵌凭据会随
spec 落盘（topology.json）——文档明示，建议受信网络或 broker 侧 ACL。

**Blocked by:** 78。

**Status:** done (2026-09-23)

- [x] MQTT 包编解码（wbtest：CONNECT 字节逐字段、PUBLISH 解析含 QoS 1 的 packet id 形状、
      剩余长度 varint 七个边界值）
- [x] 客户端状态机（`mqtt_open`：connect→CONNACK→subscribe→SUBACK，握手期限 2s 后放宽为
      读静默窗 300ms；keepalive 10s 发 PINGREQ；入站只处理 PUBLISH，防御性 PUBACK）
- [x] `mqtt_source`（首拉建连订阅 → `Quiet`/`Records`；连接错误 = Err）与 `mqtt_sink`
      （lazy 连接、会话复用、断线 = Err 且清状态）
- [x] spec：`MqttSource(String)` / `MqttSink(String)` + `mqtt_url_ok` 校验 + `pipeline run` /
      `core/pipeline` 映射（顺带修 sink detail 对所有汇写 "stdout sink"）
- [x] spec 测试：正例（源+汇）、无 topic 的 url、缺 url、未知类型例换 `amqp`（原用 `mqtt`）
- [x] 踩坑记录：MoonBit 的 `==` 比 `&` 绑得紧（`digit & 0x80 == 0` = `digit & (0x80==0)`）——
      全部加括号；已进工具链记忆
