# 77 — P18 serve 命令面：topic 家族 + group 结构化拒绝

**What to build:** `serve` 的会话分发补 `CMD_TOPIC_CREATE/LIST/DELETE` 与 `CMD_GROUP_*` 的应答：
- **topic create**：声明进 serve 自己的元数据库（与函数集同库同版本号，`create_topic` 复用）；
  `--replication-factor > 1` 结构化拒绝（"serve 是单节点；副本需要集群（sc + spu）"）。
- **topic list**：**声明 ∪ 磁盘**的并集（serve 的主题可由 produce 自动创建，只列声明会漏报；
  分区数取声明值或磁盘 partition-N 目录数）。
- **topic delete**：解除声明 + **evict 日志缓存** + 删除该主题的数据目录。这是 P16 预言的
  「第二条写入路径」——**失效必须先于它存在**：`logcache` 补 `evict_topic(data_dir, topic)`，
  删除顺序 = 先 evict 再删文件（运行中节点持有句柄时删目录 = P14 腿 8 的僵尸态）。
  删除即删数据（单机 broker 的 delete 语义，对标 Kafka）；门禁断言删后重产从 offset 0 重新开始。
- **group 家族**（JOIN/HEARTBEAT/LEAVE/COMMIT/DESCRIBE）：结构化拒绝（ERR_WRONG_ROLE +
  说明），先例 = 数据节点对 CMD_LEADER 的「placement lives with the control plane」。
  **不做** serve 上的完整协调（需要放置与 leader 地址发现——独立立项，本票留痕）。

**Blocked by:** 76（同一轮文档与提交）。

**Status:** done (2026-09-23)

- [x] `logcache.mbt`：`log_cache_evict_topic(data_dir, topic)`（按 data_dir+topic 过滤，
      返回淘汰数）
- [x] serve.mbt：`dispatch_topic_command` 共享 helper（hub 与 WS 两条路径同臂）——create
      （`create_topic` 复用；rf>1 结构化拒绝）/ list（**声明 ∪ 磁盘**并集，自动创建主题不漏报）/
      delete（`delete_topic` 容忍未声明 + **先 `log_cache_evict_topic` 再 `remove_dir_all`**，
      删后重产从 0 开始）
- [x] `adapters/fs-native`：`remove_dir_all`（递归删除，C `remove_tree`；本适配器唯一的
      递归变更，调用者拥有决策）
- [x] serve.mbt：五个 group 命令臂 = `group_coordination_refusal()`（ERR_WRONG_ROLE + 指出
      控制面；先例 = 数据节点拒绝放置命令）；serve 上做完整协调需放置与地址发现——独立小票
      候选，本票留痕
- [x] e2e-p0 新腿：rf=2 拒绝且说明 / create+list（声明∪自动创建）/ delete 后 list 不再出现、
      数据目录消失、`evicted` 有据、重产从 0 开始 / group describe 得到解释性拒绝——修后
      `e2e-p0` 全绿
- [x] 权限表核对：CMD_TOPIC_* 与 CMD_GROUP_* 已分类（SC 在用同一张表，serve 侧先鉴权后分发）
