# 84 — P21 授权模型（core/auth）

**What to build:** `core/auth` 增按主题授权：`TopicGrant{topic, read, write}`；`Credential` 与
`Identity` 各带 `grants : Array[TopicGrant]`（默认空 = 仅角色）；`authorize_topic(identity,
topic, write)` 判定第二道门。**不变量**：角色表先行（permit 在解析载荷之前，不变）；grants
只收窄；Node 与无 grants 身份直接放行。

**Blocked by:** 无。

**Status:** in progress (2026-09-25)

- [ ] `TopicGrant` + `Identity`/`Credential` 扩展（全包字面量同步——含 authenticate）
- [ ] `authorize_topic`：有 grants 时按主题匹配（read/write 分列），未匹配 = 拒绝并**按名说明**
      （无 grant / 覆盖其他主题两种措辞）
- [ ] wbtest：无 grants 放行；read grant 放行读拒绝写；write grant 反之；未覆盖主题拒绝；
      Node 放行；Root 放行；措辞含用户名与主题
- [ ] 注意：`Identity` 加字段会破所有字面量（工具链已知坑）——全包 grep 同步
