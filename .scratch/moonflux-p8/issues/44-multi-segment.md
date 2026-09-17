# 44 — 多段日志与注入式段存储

**What to build:** `SegmentedLog` 从"一个文件"变成"一串段"：注入面从 `SegmentFile` 升级为
`SegmentStore`（按 base offset 开段、列出既有段、删除整段），日志按 base offset 维护段序列并按区间
路由读取；写入落在活动段，超过阈值时在**批边界**滚动出新段。恢复只扫最后一段（只有它可能带撕裂尾；
更早的段是滚动时已 flush 的完整帧），空尾段在 open 时丢弃。

**Blocked by:** None.

**Status:** done (2026-09-17)

- [x] `core/log`：`SegmentStore{open(base)->SegmentFile, list()->Array[SegmentInfo{base,size,created_ms}], remove(base)}`
      （`created_ms` 由存储层提供，内核不读时钟）；`SegmentedLog` 持段表，`append`/`read`/`read_raw`/
      `truncate_to*` 全部按段路由；`roll_bytes` 配置（0 = 不滚动，保持单段行为）
- [x] 恢复语义：只扫最后一段；`recovery` 报告沿用；**跨段不变量**：段的 base 严格递增、相邻段无空洞
      （append 只写活动段 ⇒ 空洞不可能；open 时校验并报 `Storage` 而非静默修补）
- [x] `adapters/fs-native`：目录式布局 `partition-N/<20位零填充 base>.log`（+ 后续 `.idx`），
      `open`/`list`/`remove` 由 fs 适配器实现；`MemorySegmentStore` 供内核测试
- [x] `apps/cli/store.mbt`：`open_partition_log` 建段存储；**旧单文件布局一次性迁移**（把
      `partition-N.log` 重命名进 `partition-N/` 作为 base 0 段，重命名是原子的；迁移留一行日志）
- [x] 单测：滚动后跨段读（含跨段边界的 `read`/`read_raw`）、空尾段丢弃、段序列校验、truncate 跨段

### 关账（2026-09-17）

落地：`core/log`（`SegmentInfo`/`SegmentStore`/`MemorySegmentStore`/`SegmentSummary`；`open_store` 取代单文件
`open`——后者保留为"单段存储"的便利构造，既有调用与测试全部不变；`append`/`read`/`read_raw`/`append_raw`/
两种 `truncate` 全部按段路由；滚动在批边界后发生）；`adapters/fs-native/segment.mbt`（目录式布局
`<20 位零填充 base>.log`：`open_segment_store` + 名字即索引 + mtime 作为 created_ms）；`apps/cli/store.mbt`
（建段存储 + **旧单文件一次性迁移**（rename，原子）+ `MOONFLUX_ROLL_BYTES` 可配）；`apps/cli/node.mbt`
（`local_leo` 改为只读探测 + 打开）。

**不变量**（写进代码注释与 ticket）：段 base 严格递增（重复即 `Storage`）；**中间空段 = 空洞 → 拒绝**；
只扫最后一段做恢复（撕裂尾只可能在它）；**空尾段在 open 时丢弃**（崩溃发生在"建段"与"首次 append"之间）。

**两个真实缺陷由测试逼出来**（都留痕在测试注释里）：① `read_raw` 的"必须落在帧边界"检查被应用到了
**每一段**，跨段读因此把合法请求判成越界——检查只该问一次（回答"从哪开始"），后续段从自己的第一帧起
收；② `append_raw` 在循环里滚动时用的是**过期的 `next_offset`**（循环结束才更新），于是新段名字永远是
base 0、被存储按同名去重吞掉——**跟随者因此完全不滚动**，与 leader 的段布局发散（"follower 的段是 leader
的字节前缀"这条 P3 性质会静默失效）。修复后测试断言两侧段 base 序列与每段字节完全一致。

**门禁与布局联动**（P3/P4/P5 三处脚本按段布局更新，语义不变）：`e2e-p3-replication.sh` 的"副本字节是
leader 的前缀"改为**段按 base 序拼接后比较**（这是分身无关的正确泛化）；`e2e-p3-failover.sh` 的追平断言
补上真实的 `partition_bytes` 调用（此前它只等两个文件存在，实际是空比较——顺带修掉一个假绿）；
`e2e-p5-partitions.sh` 与 `e2e-p4-editor.sh` 改看段目录。
