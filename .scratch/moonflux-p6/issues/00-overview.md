# 00 — P6 里程碑概览（规则资产·函数集）

**门禁（可证伪）**：函数集作为版本化规则资产的完整生命周期——部署（`function-set create`）→
spec 按名引用 → 发布期静态检查拦截（缺失集合 / 集合外函数 / 不纯函数体）→ 运行期按函数变换记录 →
集合更新 + re-apply 生效（版本可见）。

**设计定调（README 决策 30/31）**
- **信任边界 = 可信资产**：函数集由平台方/运维审核部署，与表达式规则同级；mbel 表达式体函数
  本身确定性、预算内、可静态检查，宿主侧注册即可。不可信逻辑的终态是 ABI v2 标量调用
  （本里程碑只交付设计稿）与 mbel-in-guest（路线图，探针待需求）。
- **粒度**：表达式内标量函数走函数集资产；批记录变换保持现有 wasm transform，不合并。
- **与算子体系的治理同构**：工件化（JSON 文档）、版本化（单调版本）、发布期校验、预算、
  fail-closed——区别只在运行时位置（宿主侧 mbel vs wasmtime 沙箱）。

**Tickets（编号全局连续）**
- 36 函数集资产与命令面（MetadataStore.function_sets + 校验/纯度 + CLI verbs + 协议命令）
- 37 spec.functions 引用与编译链（compile_with + 静态检查 + 纯度）
- 38 门禁 + 决策记录（README 决策 30、AGENTS §8 函数集纪律）
- 39 ABI v2 标量调用设计稿（只设计不实现）+ P6 关账

**范围裁剪**：不实现 ABI v2；不做 mbel-in-guest；不做函数集集群分发（逐节点部署，
与现行逐节点 apply 一致）；编辑器不加函数集 UI（spec 引用可携带，UI 留待需求）。

**状态（2026-09-17 全部关账）**
- [x] 36 函数集资产与命令面（决策 27；README 决策编号按实际序号，计划里的 30/31 修正为 27/28）
- [x] 37 spec 引用与编译链（引用落在表达式节点：`$.spec.transforms[i].functions`）
- [x] 38 门禁 + 决策记录（`scripts/e2e-p6-functions.sh` 10 断言；AGENTS §2/§8.2）
- [x] 39 ABI v2 设计稿（`docs/operator-abi-v2-scalar.md`）+ P6 关账
