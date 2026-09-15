# 06 — 协议样本对拍脚本与兼容性矩阵

**What to build:** 把 P0 门禁"协议样本对拍通过"做成可证伪的产物：`scripts/crosscheck-protocol.sh` 从 golden vectors 真相源重生成期望并比对检入的生成模块与 CLI 的实际编码输出（防止生成模块与真相源漂移）；`docs/compatibility-matrix.md` 逐条记录对标语义（参考 Fluvio 设计要点）在 moonflux 中的验证状态（对拍通过/部分/未验证），每条注明依据与验证入口（测试名或脚本）。

**Blocked by:** 02.

**Status:** done (2026-09-15)

- [x] `tools/gen_protocol_vectors.py` 支持 `--check` 模式：重新生成 vectors_gen.mbt 并与检入版本 diff，不一致即非零退出
- [x] `scripts/crosscheck-protocol.sh`：运行 --check + 用 CLI `dev encode-hex` 对向量样本重编码比对（native 制品）
- [x] `docs/compatibility-matrix.md`：至少覆盖 记录帧格式/varint/CRC 完整性/offset 语义/恢复截断语义/消费重放语义 六条，各注状态与证据
- [x] 脚本在本地全绿；E2E（05）失败时矩阵可交叉定位到具体语义条目
