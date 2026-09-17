# 59 — 节点间安全

**What to build:** SPU↔SC（注册/心跳/领导视图/确认）与 follower→leader（SYNC_FETCH/SYNC_ACK/OFFSET_INFO）
同样走认证 + TLS。否则"内网即可信"的假设会把安全面打穿：能连上控制面就能伪造节点、能连上 leader 就能
伪造水位（HW 靠 min(LEO) 计算，伪造 ACK 直接污染提交语义）。

**Blocked by:** 57, 58.

**Status:** ready-for-agent

- [ ] 节点进程的凭据/证书配置（`--token`、`--tls-*`），`control_call`/`peer_call`/`SyncLink` 全带上
- [ ] 服务端按 `Node` 角色校验节点命令（register/heartbeat/sync_*/confirm/leader 视图）
- [ ] 门禁腿：客户端凭据调 `CMD_REGISTER` → 拒绝；节点凭据复制照常（水位推进）；TLS 之下复制逐字节一致
