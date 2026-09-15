# 07 — PipelineSpec v1alpha1（core/spec）

**What to build:** PipelineSpec v1alpha1 的内核模型与解析校验：JSON 文档 → 强类型 Spec（apiVersion/kind/metadata.name/spec.source/spec.transforms/spec.topic/spec.sink），严格校验（未知字段、非法枚举、非法名字符集、路径必填）返回结构化 SpecError 列表。spec 是单一真相源（金规则 7）：UI/CLI/运行器都只消费它。transforms 字段 v1alpha1 允许空数组并校验形态，语义执行留待 P1（mbel）。

**Blocked by:** 01（可与 02–05 并行）。

**Status:** ready-for-agent

- [ ] `core/spec` 包：Spec/Source/Sink/Topic/Transform 模型；`parse_spec(json_str) -> Result[PipelineSpec, SpecErrors]`
- [ ] 校验规则：apiVersion==`moonflux.io/v1alpha1`、kind==`Pipeline`、name 为 DNS-1123 标签、source.type∈{file} 且 path 非空、sink.type∈{stdout}、topic.name 合法、transforms 每项有 type 且形态合法（v1alpha1 仅允许空数组或保留项校验）
- [ ] 错误结构化：`SpecError{ path, code, message }` 列表（一次解析报全部错误，便于编辑器后续标错）
- [ ] 单元测试 + 非法语料（数据文件真相源 + 生成模块，同 02 模式）：缺字段/错枚举/坏名字/未知字段/多余 JSON 类型
- [ ] 双后端 `moon test` 通过（纯解析，零 IO）
