# 97 — 内核侧：函数集会话与资产文档（apps/editor-kernel）

**What to build**：编辑器内核获得函数集资产的三种能力——spec 引用、资产文档构建、CRUD 会话——全部走既有 core 包，页面不见字节。

- `mf_editor_build_spec`：expr 变换图节点接受可选 `functions`（字符串 = 集合名，非空才写入 spec）；wasm 节点带 `functions` → 报错（只有 expr 变换能引用函数集）。spec 校验/编译路径不变（`core/spec` 本就认这个键）。
- 新 `mf_editor_build_function_set(form_json)`：表单 JSON（`{name, functions:[{name,params,body,description?}]}`）→ 资产文档 JSON；只做形状预检（集合名走 `@spec.valid_topic_name`、至少一个函数、函数名非空、params 是字符串数组、body 非空；description 空则省略）。**不复制** mbel 规则与纯度扫描——节点的发布期门禁是唯一权威。
- 新请求构建器：`mf_editor_function_set_create(asset)` / `_list()` / `_delete(name)`（命令 22/23/25；GET 留给 CLI——LIST 应答已是全量文档，页面不需要第二个读取路径）。
- `mf_editor_feed` 扩展 CMD_OK 解码：records/applied 均不命中时尝试 JSON——数组 → `kind:"function-sets"`（LIST 应答，元素即 `encode_function_set_doc` 的文档）；带 `created` 的对象 → `kind:"function-set"`（CREATE 应答 `{name,revision,created}`）。JSON 载荷与本会话其余 OK 应答（produce/fetch/apply 的二进制）按首字节互斥，注释留痕。
- `mf_editor_abi_version` → **2**（页面据此识别旧制品：门禁 setup 拷贝的内核若未重建，面板静默缺失是最坏结果——版本断言钉住）。

**Blocked by**：无。

**Status**：done（2026-10-05）

- [x] build_spec 携带/拒绝 functions
- [x] build_function_set（形状预检，单权威声明）
- [x] create/list/delete 请求构建器
- [x] feed 解码两种函数集应答
- [x] ABI 2 + wbtest 11 条：build_spec 双侧、表单预检全分支、帧命令字节、应答解码、records 回归）


**落地实录**：执行中抓到 `mf_editor_feed` 的 apply 应答试探会误读**长** JSON 应答（`[` 91 / `{` 123 过 uleb 长度上界）——修法为 JSON 解码先行，长夹具回归钉死（短夹具当年全绿是教训）。GET 构建器有意不做：LIST 应答已是全量文档，页面不需要第二条读取路径。
