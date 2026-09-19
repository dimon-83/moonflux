# 65 — 键语义启用：produce 能设键，链路上看得见

**What to build:** `produce` 增加两个互斥的键来源——`--key K`（全部记录同键）与
`--key-separator S`（每行**首个**分隔符拆成 key/value；无分隔符的行**跳过并告警**，
末尾汇总条数；对标评估报告 §2.3.4）。键经连接器的共享塑形规则产生，本地与远程路径同一份
实现；`consume` 第三列既有，无需改动。

**Blocked by:** 无。

**Status:** done (2026-09-18)

- [x] `apps/connectors`：`KeyMode { NoKey | ConstKey(Bytes) | SplitAt(String) }` +
      `records_from_text_keyed(text, timestamp, mode) -> (Array[Record], Int)`（第二个分量 =
      跳过的行数）；`records_from_text` 保持既有签名（委托 NoKey，pipeline 路径行为不变）
- [x] `apps/cli/produce.mbt`：解析 `--key` / `--key-separator`（互斥；空分隔符报错），
      经 `file_records` 透传到本地与远程两条路径；跳过行用 `warn()` 报 stderr，末尾一条汇总
- [x] `main.mbt` 用法文本补两个旗标
- [x] 测试：`connectors_wbtest`（拆键、CRLF、空行、无分隔符跳过计数、空键行）；
      `consume` 的 4 列契约不受影响
