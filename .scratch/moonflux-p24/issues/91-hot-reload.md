# 91 — 无重启轮转：TLS 上下文与凭据表热重载

**What to build:** 决策 35/production-readiness 点名的"证书轮转"。机制选 **mtime 监视**而非
SIGHUP：无需信号垫片、跨平台、与 cert-manager 的挂载密钥替换语义天然契合。三个服务端
（serve/sc/spu 共享 hub）各自在既有 housekeeping 节拍上检查：

- TLS 证书/私钥/CA 文件 mtime 变化 → 重建 `TlsContext` 换入 hub（**新连接用新证书**；
  在途握手用旧上下文走完或自然消亡；已建立的连接不受影响——它们握过手了）
- `auth.json` mtime 变化 → 重新加载凭据表换入 `AuthGate`（新连接按新表认证；已认证连接
  保留身份到自然断开）；每次重载 note 一行（凭据数），审计不见凭据本体
- 启动行：**认证开启而无 TLS → 明文警告**（凭据走明文线上）——P12"必须大声"纪律的延伸

**Blocked by:** 无。

**Status:** done (2026-09-25)

- [x] `ConnectionHub.tls` 改 `mut` + `rotate_tls`；`AuthGate.config` 改 `mut`
- [x] `rotation.mbt`：watcher（路径 + 上次 mtime）+ `rotate_if_changed`（stat µs 级，1s 节拍
      不伤环长）
- [x] 三服务循环挂点 + 重载 note 行 + 启动明文警告（announce_auth_mode 感知 TLS 状态）
- [x] wbtest：mtime 变化触发/未变化不触发/文件消失不炸
- [x] SASL 边界决策（决策 48）：自有面 token-over-TLS 覆盖同一威胁（明文+认证的组合用
      警告而非第二套机制缓解）；Kafka 连接器侧 SASL/TLS 是互操作候选（决策 44 边界）
