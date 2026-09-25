# 92 — 轮转门禁与文档

**What to build:** `scripts/e2e-p24-rotation.sh`；全部文档同步。

**Blocked by:** 91。

**Status:** done (2026-09-25)

- [x] 腿 1：serve 持 CA1 签的证书 v1 + 凭据 A → 新 CA1 客户端可用、token A 可用
- [x] 腿 2：替换为 CA2 签的证书 v2 + auth.json 换凭据 B → 等 housekeeping（>1s）→
      **不重启**：CA2 客户端握手成功、**CA1 客户端被拒**（服务端已呈现新证书）、
      token B 被接受、token A 被拒；serve 日志有重载 note
- [x] 腿 3：SC 同机制——轮转后控制面命令用新 CA 可用
- [x] 腿 4：认证开启 + 无 TLS → 启动日志含明文警告行
- [x] gates.sh 加步（40 → 41）
- [x] 文档：architecture.md:202 陈旧表述修正（ACL/审计已 P21 交付）；feature-matrix 81 行
      拆行（ACL✅/审计✅/轮转✅/SASL 边界声明）；user-guide 运维节加"无重启轮转"；
      AGENTS P24 行 + P12 纪律块补一条；README 决策 48；roadmap + 看板
