# 点位恒值（卡值）监控 —— 用 moonflux 做，并做成可长期运行的部署

**需求**：某厂 PostgREST 数据源 `ia_csc.inlet_node_value`（点位 `CN_进水COD`）持续取最新值，
在**滑动的 10 分钟窗口**里判断是否出现恒值/卡值；实现要用 **moonflux**，部署物放在**工程外**
（`~/workspace/citics-plant-monitor/moonflux/`），不得静默降级，边界如实写下。

判定逻辑**全部**是平台能力（新算子 + 时间戳解析 + http 源的请求头/https/SNI + http 汇的
headers/ca），部署目录只有 spec 与单元文件。

| 期 | 内容 | 门禁 | 状态 |
| :--- | :--- | :--- | :--- |
| ① | `apps/operator-stuck`：有状态（状态主题）、事件时间驱动不读时钟、水位去重、**断流记录但不切断段**、坏样本两方向都不算证据、解除告警迟滞、可疑值（满量程）即刻告警、段统计供标定 | `e2e-p43-stuck.sh` 7 腿 + 与独立参考实现（4 天 5732 条真实数据）对拍 | ✅ 决策 88 |
| ② | 时间戳解析放宽到真实 feed 形状：**微秒校验后截断** + **接受固定偏移**（`+08:00`） | native/wasm 各 16 条 wbtest（含真实形状） | ✅ 决策 89 |
| ③ | http 源 **请求头**（含 CR/LF 注入守卫、排序确定） | `e2e-p44-http-headers.sh` 5 腿（**断言对端收到的头**） | ✅ 决策 90 |
| ③ | http 源 **https/TLS**（显式 CA、缺 ca 校验期按名拒绝、无隐式系统信任库） | `e2e-p45-http-tls.sh` 6 腿（含错锚/名字不匹配/SNI 的拒绝路径） | ✅ 决策 91 |
| ③ | **TLS 发 SNI**（`SSL_ctrl`；`SSL_set_tlsext_host_name` 是宏不是符号 ✗）→ **真实端点直连成功** | p45 的 SNI 腿（夹具拒收无 SNI 握手）+ 实机直连 | ✅ 决策 92 |
| ④ | 部署产品化：两段管道（判决落主题键＝点位／STUCK 外发 webhook）+ systemd/launchd + logrotate + **重启即重放**；http 汇补齐 headers/ca | `e2e-p46-deploy-routing.sh` 4 腿 | ✅ 决策 93 |
| ⑤ | 文档同步：README 决策 88–93、feature-matrix、roadmap、board、部署指南（工程外 `moonflux/README.md`）、本 ticket | gates.sh 含 p43–p46 + `audit-shell-vars.py`；CI 四条腿 | ✅ |
| ⑥ | **外部失败重试**（源/汇退避、进程不死、汇批次不丢） | `e2e-p47-poll-retry.sh` 4 腿 | ✅ 决策 94 |
| 后续 | 更多点位（每点位一条 spec；`nodes` 级别的批量生成）；告警按**时段**基线化（实测最长恒值段集中在凌晨 02:45–04:45 ✗）；GuestTrap 错误文本里中文不可读 ✗；`operator-stuck` 的红旗值清单按点位维护 | — | ⏳ |
