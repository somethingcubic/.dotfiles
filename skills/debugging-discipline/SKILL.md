---
name: debugging-discipline
description: 通用 debug / RCA 纪律。收到 bug、排查故障、定位根因、复现问题、回归验证时必读。核心：提假说前必列对立假说 + 证伪测试；先止血再 RCA；读实现不读符号名；跨机分布式观测先于代码 RCA。Triggers：bug、排查、RCA、复现、根因、故障、异常、报错、fix、debug。pipeline 积压/吞吐类走 pipeline-debug-protocol。
---

# Debugging Discipline

> 通用 debug 流程，独立于具体领域。pipeline 类积压/吞吐有专属协议见 `pipeline-debug-protocol` skill 和 CLAUDE.md 事故排查节，本 skill 管"提假说 / 验证 / 收敛"的通用纪律。

## 提假说前必须列对立假说

**不允许只提一个假说就开始验证。** 至少列 2-3 个互斥的根因候选，对每个写：

```
假说 N：<根因>
  证伪测试：如果 N 成立，应该观察到 <X>；观察不到 → 否定 N
  优先级：先验证证伪成本最低 / 信号最强的
```

只有一个候选 = 思路漂移信号，停下来想想"还有什么可能"。

## 跨范围枚举

对涉及 N 个组件 / topic / 服务的问题，**不允许聚焦单个对象下结论**。例：

- "broker 102 REQTMOUT" → 不能只看 broker 102，要看所有 broker 的 REQTMOUT 分布
- "scheduler 卡住" → 不能只看 scheduler，要看 dispatcher / worker / DB 的全链路时间戳

否则就是局部推断，必须标 [局部推断]。

## 读实现，不读符号名

- `BatchWriteXxx` 可能是 sequential loop
- `RetryWithBackoff` 可能写死 1 次
- comment 自称的"原子操作"可能不在事务里

**任何"X 做 Y"的断言**必须带 `file:line` 锚点 + 引用关键代码行。grep 函数名找到定义，然后真的读 body。

## 假说收敛纪律（防跳跃）

**当前假说必须被显式证伪才能跳到下一个。** "感觉不太对"、"换个思路试试"不算证伪。证伪 = 给出否定证据（grep 结果、日志、复现失败）并记录：

```
假说 N：<根因>
  证伪证据：<具体命令输出 / 代码引用 / 日志>
  结论：否定，因为 <事实与预期不符>
```

升级规则：
- 连续 3 个假说全被显式证伪 → **强制 blocked report**（已排除假说 + 否定证据 + 当前最可信方向 + 还缺什么信息），升级给 orchestrator 或用户，不许继续猜
- 被反问时**稳住当前假说追到底**，不跳新假说；当前假说确认死了才开下一个

## Bug 分诊协议

收到 bug 后的强制顺序：

1. **止血判断**：先判断是否有当前用户 / 生产影响；若存在可逆、低风险、证据足够的 mitigation（rollback、暂停入口、限流、关闭任务、恢复临时开关），先走授权路径止血并记录恢复条件
2. **提取可观测事实**：从错误信息、日志、复现步骤中提取所有已知事实（不推断、不解释）
3. **读相关实现**：基于事实中的函数名/文件名/错误码，grep 找到定义，读 body（不是读符号名猜）
4. **列假说**：基于事实 + 代码，列 2-3 个互斥假说（遵循"提假说前必须列对立假说"）
5. **逐个证伪**：按证伪成本排序验证（遵循"假说收敛纪律"）
6. **Root cause**：用 `file:line`、日志或复现结果锚定最小根因；区分触发条件、失败边界和受影响范围
7. **修复 + 复现测试**：修完必须有复现测试或等价验证证明 bug 被修复
8. **清理止血措施**：root cause 修复验证通过后，恢复临时开关 / 限流 / 暂停项，记录残留风险

**禁止**：跳过步骤 1-3 直接写假说（= 基于训练数据猜，不是基于代码事实推）；把 mitigation 当 root cause fix；止血后不继续 RCA

## 被 review 拒掉的修复禁止原样重提

见 `commit-style.md` Review 拒了不要原样重提节。

补充：reviewer 拒掉后**不要立刻反驳**。先做：

1. 复述 reviewer 的反驳论点
2. 检查你自己的证据是否站得住（grep / log / 复现）
3. 列举对方可能漏掉的事实 vs. 你可能漏掉的事实
4. 再决定接受 / 部分接受 / 据理拒绝

机械接受和机械拒绝都是错的。

## 跨机 / 分布式：观测先于代码 RCA（真因可能在代码之外）

"读实现不读符号名"管的是"读对代码"；但跨机/多 fleet 系统里，**读对了代码仍可能错——因为真因在代码之外**（服务器侧 ad-hoc 基建、手搓代理/tunnel、被覆盖的有效环境变量、未入 git 的 infra config）。

- **观测先于行为变更**：一个指标在多机/多 fleet 系统里降不下来、而代码 RCA 给出"高置信"结论却修不动时，先给"静默路径"加 `reason=` 级观测（cheap、零行为变更）拿到真实分布，再动行为。代码推理链的自洽 = "高置信"，但**不等于 prod 验证**。
- **枚举所有 fleet 取证**：同一逻辑可能跑在多台机器（如主 + scaleout）。单机 grep 会得出"没人碰过这条记录"的假象。每台都查。
- **配置真值看进程有效环境，不看 `.env` 文件**：以 `/proc/<pid>/environ` 或 supervisor/systemd 注入的 `environment=` 为准；`.env` 可能被覆盖。对齐"配置不许猜"。
- **手搓 transient 旁路放主干上 = 隐形单点**：发现某依赖经临时/手搓代理访问、而同类依赖是直连时，优先删旁路回归直连惯例（并保证 SoT 可追溯），不要把旁路持久化。

## 教训锚点

- 2026-06-28 derive-step-stuck 残留：4-agent 对抗式代码 RCA 达 HIGH 置信归因 `completeAndNotify` early-return guard arm，方向性错误。Phase-0 加 `reason=` 静默路径观测后才暴露真因——scaleout 整队经一个白名单 IP 写错的临时 python Redis 代理连不上 Redis（`callback_nil`），回调被禁用、全丢 reconciler。真因纯代码读不可见（跨机 + 服务器侧 ad-hoc 代理 + 被覆盖的有效 env）。详见 `~/.claude/postmortems/2026-06-28-derive-callback-orphan-scaleout-proxy.md`。
- 2026-04 broker 102 REQTMOUT 案：盯死一个 broker 的一种错误，没扫所有 topic/partition，绕了一圈才发现是订阅完整性问题。
- 2026-04-22 YT video_detail 积压 → `~/.claude/postmortems/2026-04-22-yt-video-detail-backlog.md`
