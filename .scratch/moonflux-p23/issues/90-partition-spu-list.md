# 90 — partition list 与 cluster spu list

**What to build:** cli-roadmap §3.3 承诺的两条观测命令（P7/P8 落地后缺的只是命令本身）。

- `partition list --topic T`：平表 PARTITION/LEADER/REPLICAS/HW/LEO——纯客户端组合既有
  命令（topic list 定分区数 → 每分区 LEADER + OFFSET_INFO），集群（SC）与单机（serve，
  P22 起应答 LEADER）同一实现；无 leader 显 "election pending"，leader 不可达显 "?"。
- `cluster spu list`：SPU/ADDRESS/ROLE/HOSTED/TOPICS——节点注册表 + **客户端组合**的
  承载计数（topic×partition 的 LEADER 视图里数副本归属）；磁盘字节需要节点上报
  （协议加法段），本票不做、留痕。

**Blocked by:** 89（同一轮命令面，门禁共用）。

**Status:** done (2026-09-25)

- [x] `partition list`（cluster.mbt 新动词；对 serve 与 sc 双验证）
- [x] `cluster spu list`（对 sc；serve 无节点注册表 → 结构化报错说明）
- [x] `topic add-partition` **不在本票**：需要放置调和，是元数据面的扩展不是命令面尾巴，
      如实标注未排期
- [x] 门禁 `scripts/e2e-p23-cli.sh`：serve 侧 partition list 值与 offsets 一致；
      spu list 字段与承载计数；profile 往返与优先级
- [x] cli-roadmap §3.3.1 回填 + §3.3.2 过时注修复（"缺的只是命令"的历史成立、现关闭）
