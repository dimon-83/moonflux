# 17 — 算子接入数据路径 + 语义对拍

**What to build:** 把 wasm 算子接进消费路径（transform 链新增 `wasm` 类型，与 mbel expr 并列）；
建 P2 门禁的可证伪对拍：同一批 golden records 分别经 (a) MoonBit 原生实现 与
(b) wasm 算子执行，输出字节级一致；CLI `pipeline plan/run` 与 spec 校验同步扩展。

**Blocked by:** 15, 16.

**Status:** ready-for-agent

- [ ] core/spec：transforms 项新增 `{ "type": "wasm", "module": "...", "export": "..." }`
      （校验 + 语料扩展）；core/pipeline compile 映射（capability 标记 wasm-p2）
- [ ] serve/run 的 transform 链支持 wasm 算子节点（预算与错误路径与 mbel 同策略：fail-closed）
- [ ] 对拍框架：`scripts/crosscheck-operators.sh` —— identity 与 to_uppercase 算子
      native-vs-wasm 输出 diff 断言（golden records 数据文件真相源 + 生成器模式）
- [ ] 集成测试：算子 trap → 结构化错误不吞记录；预算超限 → 明确报错
