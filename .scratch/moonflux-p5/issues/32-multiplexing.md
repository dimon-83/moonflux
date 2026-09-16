# 32 — 连接多路复用（事件循环）

**What to build:** 把"accept → 处理到连接结束 → accept 下一个"改成**事件驱动多连接**：所有活跃连接
一起 poll，谁有数据就给谁推进协议状态机；空闲/挂起的连接不占用其他人的服务时间。仍然是单线程
（不引入 async 运行时），与既有的"节点循环 + 定时家务"形态一致。

**Blocked by:** 无（P4 门禁暴露的缺口）。

**Status:** ready-for-agent

- [ ] `net-native` 原语：`set_nonblocking`、`recv_some`（would-block 与 0 字节/错误可区分）、
      `poll_readable(fds, timeout_ms)`（返回就绪下标）；带单测（多 fd 并发、超时、挂起 fd 不影响其他）
- [ ] 每连接状态机：入口缓冲 + 帧解析 + 应答排队；**部分帧不阻塞整环**（半个头到达也能等下一轮）
- [ ] `serve`：accept 循环改为注册到事件循环；HTTP 升级（WS）在事件循环内完成，升级后按 WS 帧推进
- [ ] `spu` / `sc` 同样接入（同一个循环实现，避免两套）
- [ ] 慢客户端策略：写缓冲有上限，超限断开并报告（不能因为一个不读的客户端吃满内存）
- [ ] 门禁 `scripts/e2e-p5-concurrency.sh`：浏览器长连接（或等价的挂起 WS 连接）+ 2 个 CLI 客户端
      并发 produce/consume 全部成功；一个"连上但不读"的客户端存在时，其他客户端延迟仍在秒级
