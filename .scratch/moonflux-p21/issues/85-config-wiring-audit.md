# 85 — P21 配置、接线与审计

**What to build:** auth.json 的凭据条目增可选 `grants`（`[{"topic": ..., "read": ..., "write": ...}]`，
未知键拒绝、topic 过 `valid_topic_name`、全 false 拒绝、重复主题拒绝）；`authenticate` 把 grants
带入 Identity；**三处分发入口**（serve 的 hub 会话、serve 的 WS 单连接、spu 数据面）对主题类
命令做 `authorize_topic`——在主题解析后、触碰日志前；**审计日志** `<data-dir>/audit.log`（JSON
行：ts/user/role/cmd/topic/decision/reason），记录拒绝、认证失败与主题生命周期，**凭据永不入**。

**Blocked by:** 84。

**Status:** in progress (2026-09-25)

- [ ] `apps/cli/auth.mbt`：grants 解析与校验（未知键/空名/全 false/重复主题 fail-fast）+
      announce 提及 ACL 数量
- [ ] `dispatch_produce / dispatch_produce_partition / dispatch_fetch / dispatch_fetch_partition /
      dispatch_fetch_committed` 增 identity 参数并在主题解析后判定；CMD_COMPACT / CMD_SEGMENTS /
      CMD_OFFSET_INFO 臂内判定（serve 双路径 + node 数据面同享）
- [ ] `apps/cli/audit.mbt`：append 每事件即落盘（拒绝是状态迁移不是每记录，open-append-close
      足够）；写失败走 stderr warn（审计写不进去必须可见）
- [ ] 钩子：认证失败（AuthGate/identify 路径）、permit 拒绝、authorize_topic 拒绝、
      topic create/delete（serve 臂 + sc 处理器）——**凭据/token 永不写入**
- [ ] WS 路径核对：handle_connection 的认证与 identity 流转与 hub 一致
