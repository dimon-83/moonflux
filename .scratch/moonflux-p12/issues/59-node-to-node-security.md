# 59 — 节点间安全

**What to build:** SPU↔SC（注册/心跳/领导视图/确认）与 follower→leader（SYNC_FETCH/SYNC_ACK/OFFSET_INFO）
同样走认证 + TLS。否则"内网即可信"的假设会把安全面打穿：能连上控制面就能伪造节点、能连上 leader 就能
伪造水位（HW 靠 min(LEO) 计算，伪造 ACK 直接污染提交语义）。

**Blocked by:** 57, 58.

**Status:** done (2026-09-17)

- [ ] 节点进程的凭据/证书配置（`--token`、`--tls-*`），`control_call`/`peer_call`/`SyncLink` 全带上
- [ ] 服务端按 `Node` 角色校验节点命令（register/heartbeat/sync_*/confirm/leader 视图）
- [ ] 门禁腿：客户端凭据调 `CMD_REGISTER` → 拒绝；节点凭据复制照常（水位推进）；TLS 之下复制逐字节一致

### 关账（2026-09-17）

落地：`PeerLink{token, tls}`（一个值贯穿**所有**节点间调用——控制面的注册/心跳/领导视图/确认/资产拉取、
follower→leader 的复制链接、peer 调用），`spu`/`sc` 用同一套 flags 既服务又出站（`--tls-cert/--tls-key`
服务本端口，`--tls-ca` 既是出站信任锚也是（配 `--tls-require-client`）校验对端的锚）。控制面的**五条 CLI
路径**也改为携带 link——顺手修掉了 `pipeline apply --remote` 一直**不带凭据**的疏漏（它与其余命令走同一个入口，
所以一起收敛）。**"不认证的控制调用"被删除**：`control_call` / `control_call_with_timeout` 在最后一个调用者
转换后即删——留一个"忘带凭据"与"故意不带"长得一样的 helper 是陷阱。

**三个实测发现**（都留痕，都有修法）：

1. **TLS 会话没有 `SO_RCVTIMEO`**。明文路径靠 socket 选项兑现"节点不得挂住节点"，TLS 路径上这个保证会
   静默消失——握手有界并不覆盖"对端在握手**之后**装死"。修法：`conn_over_stream(stream, timeout)` 用
   期限强制读写（`tls_conn_with_timeout` 把节点的调用期限传进去），并把 `tls_conn`（无限等待的版本）整体删除，
   让"同一条 TLS 字节通道"只存在一份实现。
2. **错误码一直在撒谎**。垫片对失败一律返回裸 `-1`，而适配层把 `-n` 当 errno 解码——于是**每一个** socket
   错误都报成 `Io(errno=1, op=recv)`（"连接被重置"被显示成"权限不足"，指错方向）。修法：垫片返回 `-errno`
   （保留两个哨兵码），并加 `mf_net_strerror` 让消息变成 `Io(errno=54 Connection reset by peer, op=recv)`。
   这是安全门禁第 6 腿逼出来的：门禁要断言"明文客户端被拒"，而拒绝的信息必须可读。
3. **门禁可能在测上一轮的二进制**。所有 E2E 脚本都写着"优先 release、退回 debug"，而 `moon build --target
   native`（以及 `moon test`）只产出 **debug**——只要机器上碰巧存在一个 release 构建，门禁就会静默地测它。
   这次就被咬到（安全门禁首跑用了一个 12 分钟前的 cli.exe，表现成"凭据没生效"）。修法：21 个脚本统一改为
   **优先 debug**，且 `gates.sh` 显式 `export MOONFLUX_EXE`，把"这套门禁测的就是这次构建"从巧合变成事实。

**已知边界（记入 README 待办）**：控制面仍是"一次一条连接"的阻塞式 accept 循环，加上 TLS 握手期限 500ms，
一个只会连上不说话的探测者能让 SC 忙上若干个期限，从而让健康节点错过 3s 存活窗而被判离线、触发一次不必要
的选举（门禁第 6 腿之后确实观测到过一次，第 7 腿因此改成"等 leader 出现"而不是假设）。**有界、可自愈、不丢数据**，
但结构性修法是把控制面也换成 hub（与数据面同构）——列为后续工作，不在本 ticket 内做。

**门禁实证**（`scripts/e2e-p12-security.sh`）：5a 客户端凭据伪造 REGISTER → `code 10`；5b 客户端凭据发
SYNC_ACK → `code 10`（**高水位无法被客户端推动**）；5c 同一条命令换 node 凭据 → 被接受（证明拦的是角色而不是墙；
那条幽灵 REGISTER 真的进了副本集合、该分区 HW 停在 0——这正是"节点凭据不能给客户端"的实证）；7 腿 TLS +
认证之下三分区复制**逐字节一致**。
