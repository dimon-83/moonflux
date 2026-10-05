# P27：编辑器函数集 UI（overview）

**定位**：roadmap「下一梯队」第一项（决策 50 收口时议定的 6 部分范围）——编辑器（`web/editor/` + `apps/editor-kernel`）获得函数集（P6 规则资产）的管理与引用面。

**6 部分议定范围**：

1. **面板**——列出节点上的函数集（名称 / revision / 函数数），刷新、删除、载入表单；
2. **编辑表单**——资产文档（集合名 + 函数的 name/params/body/description）的编辑与部署（CREATE）；
3. **表达式选择器**——expr 变换节点可从已知集合中按名引用（spec 的 `transforms[i].functions`）；
4. **修订漂移提示**——引用集合的 revision 在上次部署之后前进时给出「re-apply」提示（编辑器侧事实，服务端真相仍是 `topology.json`）;
5. **不含标量函数**——UI 不暴露 ABI v2 标量函数的任何编写面（不可信标量函数的路径是沙箱，不是可信资产）；
6. **门禁形态**——`scripts/e2e-p27-editor-functions.sh`，与 p4-editor 同形（setup / drive / verify；浏览器阶段由 agent/人驱动），外加内核侧 wbtest（进 `moon test` 套件）。

**不变量（P4/P6 纪律的延伸）**：

- 页面仍不拼装 spec、不拼装协议字节、不解析资产格式——三者的构建全部在 `apps/editor-kernel`；
- 资产的本地预检只做**形状**（名字白名单复用 `core/spec::valid_topic_name`）；mbel 名字/参数/函数体规则与纯度以节点的发布期门禁为唯一权威——编辑器不写第二套；
- 函数集 CRUD（22–25）在认证开启时仅 Root 可用（`core/auth.permit` 闭合表的既有事实）；编辑器会话与 P4 一样不带凭据——函数集 UI 的口径是本地/免认证姿态，错误应答（如 `ERR_AUTH_REQUIRED`）原样进日志面板；
- 漂移提示是**编辑器侧的 advisory**（部署时快照引用集合的 revision，LIST 发现前进即标记）；服务端权威事实是 `topology.json` 记录的绑定 revision（门禁断言它，不断言像素）。

**Tickets**：97 内核侧 · 98 页面侧 · 99 门禁与文档。编号全局连续（承 96）。
