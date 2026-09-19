# 68 — P14 门禁与文档同步

**What to build:** `scripts/e2e-p14-compaction.sh` 进 `gates.sh`（31 → 32 步），7 条腿；
同步全部文档（README 状态行与数据面行、决策记录、feature-matrix、compatibility-matrix 新增
「去重 / 键控压实」行、architecture §5 存储不变量、user-guide §7 运维与 §11 脚本索引、
cli-roadmap 回填、AGENTS §2 阶段表与 P14 纪律块、project-roadmap）。

**Blocked by:** 67。

**Status:** ready-for-agent

- [ ] 腿 1 键链路：`produce --key K` 与 `--key-separator ':'` 的记录在 `consume` 第三列可见；
      无分隔符行被跳过并在 stderr 汇总
- [ ] 腿 2 压实效果：同一键多条 → 只有最新存活；**存活记录的偏移与压实前逐一相等**；
      空洞两侧仍可分别读
- [ ] 腿 3 floor 保护：段末 > floor 的段不动（未提交/未过组地板的键不删）
- [ ] 腿 4 幂等：第二遍压实空报告、段文件字节不变
- [ ] 腿 5 复制收敛：RF=2 两节点各自 `cluster compact` 后逐段 `cmp` 一致；新副本加入
      被压实的日志能追上（空洞跳跃腿）
- [ ] 腿 6 压实后重启：恢复干净（无 discarded 字节），`cluster segments` 自洽
- [ ] 腿 7 空键保护：无键记录永不删除（`--key` 与普通 produce 混跑）
- [ ] 文档同步（README/AGENTS/architecture/feature-matrix/compatibility-matrix/user-guide/
      cli-roadmap/project-roadmap）+ README 决策记录编号勘误（文末引用「决策 37」但列表里没有
      37 号条目——补上文档重构条目，P14 记 38）
- [ ] `scripts/gates.sh` 全量回归（32 步）通过
