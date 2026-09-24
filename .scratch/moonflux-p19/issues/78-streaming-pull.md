# 78 — P19 连接器框架三态 pull + run 循环

**What to build:** `Source.pull` 的返回从 `Result[Array[Record], String]` 升级为
`Result[SourcePull, String]`：`Records(Array[Record])`（有数据）/ `Quiet`（流式源此刻无数据）/
`Exhausted`（一次性源已耗尽）。`pipeline run` 从"一次 pull 就退出"改为循环：`Records` → 追加
+ 变换 + 汇 后继续拉；`Quiet` → 短睡再拉；`Exhausted` → 退出 0。file/stdin/http 三个一次性源
各自记录"已交付"状态（第二次 pull 即 `Exhausted`）——**既有行为逐字节不变**（同一份数据只
处理一次、退出码不变），流式源不必有第二套接口。

**Blocked by:** 无。

**Status:** done (2026-09-23)

- [x] `apps/connectors`：`SourcePull` 枚举 + `Source.pull` 签名 + 三源改造（`OnceState` 记已
      交付：file/stdin/http 第二次 pull 报 `Exhausted`）；`connectors_wbtest` 同步（含
      "一次性源不重放"的显式断言）
- [x] `apps/cli/pipeline.mbt`：run 循环（`Quiet` → `cli_sleep_ms(50)`，空 `Records` 同 Quiet，
      `Exhausted` → exit 0）；sink 构造提前到循环外（流式运行多批共用一个会话）
- [x] 回归：`e2e-p0p` / `e2e-p1-connectors` / `e2e-p1-rules` 全绿（一次性语义逐字节不变）
- [x] wbtest：三态语义（Records→Exhausted；错误保留重试语义——读失败不置 delivered）
- [x] 顺带：stdout 汇每批 flush（被重定向的 stdout 块缓冲；流式 run 不自行退出——P4 教训）
