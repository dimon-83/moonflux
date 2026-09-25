# 89 — profile 配置档案

**What to build:** cli-roadmap §3.1 的 `profile` 承诺——多环境连接档案，替代每次裸传
`--remote`。本地 JSON 配置（`~/.moonflux/config`）：`profile add/list/use/remove`；
命令侧统一解析 `remote_of(flags)`：**显式 `--remote` 优先 → current profile → 报错**。
token 可入档案（与 `--token` 同一语义：旗标优先、档案兜底、环境变量再兜底）。

**Blocked by:** 无。

**Status:** done (2026-09-25)

- [x] `apps/cli/profile.mbt`：config 读写（原子写、损坏即结构化报错）、四个动词
- [x] `remote_of(flags)` 替换全部 28 处 `flags.require("remote")`/`flags.get("remote")`
      —— 单一解析点，错误文本说明三段优先级
- [x] wbtest：config 往返、current 语义、显式旗标压过档案
- [x] 凭据留痕：token 明文存于 `~/.moonflux/config`（与 ~/.fluvio/config 同类），文档写明

**与立项的差异**：token **不入档案**（立项写的是"token 可入档案"）——实现时按 P12 纪律
改为**加载期按名拒绝** token 条目：凭据已有 `--token` / `MOONFLUX_TOKEN` 两条口径，第三条
静默口径等于替用户做一个它没做的安全决定。若将来要档案带凭据，单独立项。
