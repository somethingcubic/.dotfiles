# Postmortem: derive-step-stuck 残留排查 — Phase-0 观测推翻高置信代码 RCA，真因是 scaleout 隐藏代理

**日期**: 2026-06-28
**项目**: ordo_ai (refresh engine), `/Users/qiansenmiao/Documents/Projects/ordo_ai_samuel`
**严重程度**: 中（生产 reconciler ~300-400/min 自愈式残留 + twitch 一度积压；全程业务零损失，但两次"修复"未中真因）

## 时间线

- **背景**：`reconciler.go:531` "derive job already success but step stuck" 系统级 ~250-740/min，reconciler 成了约半数 derive 完成的实际收口路径；twitch 一度积压（~4 SUCCESS/h）。
- **#2005（前序）**：把回调从可重绑的 `job.StepID` 改成 dispatch-time `expectedStepID`，修了 *misroute* 类（advanced 31%→46%）。gate 未达，falsification 证明残留是 *orphan* 类（步骤零回调）。
- **Rank 1 / #2007**：`completeAndNotify` 改 fan-out——`GetStepsByRefreshID` 后对"本 content_type + dispatch 覆盖的 phase"的每个 running derive step 发回调。TDD（红测先行）、Codex LGTM、部署两台。**gate 仍未达**：reconciler 持平 ~300/min。trace 证明 fan-out 确实在工作（~400/min advanced），但残留没降。
- **决策点**：proxy gate（<10/min）未达，但业务 gate 全好（twitch 追平、各平台 parity、无 double-complete）。预案是"未达即回滚 #2005+#2007"，但数据显示回滚会把 ~400/min in-band 推回 reconciler = 更糟。用户拍板：保留 + 起草 Rank-1b。
- **Rank-1b Phase-0 / #2008**：给 `completeAndNotify` 每个静默 early-return 加 `reason=` 日志（observability-only，零行为变更）。**这一步是转折**。
- **真因暴露**：Phase-0 数据显示 main box early-return 极少（~3-13/min），而 **scaleout 机队 862 条 `reason=callback_nil`**——整队 `w.onDeriveComplete==nil`。根因：scaleout 经一个临时 python 代理 `refresh-redis-canary-proxy`（`172.16.0.85:16379→127.0.0.1:6379`）连 Redis，但代理 `ALLOW={172.16.0.11}` 写错了 IP（scaleout 实际是 `172.16.0.212`）→ 每个连接被踢 → Redis EOF → 回调禁用 → 每个 derive 完成全丢 reconciler。
- **止血**：修代理白名单（加 172.16.0.212）+ 重启 scaleout worker → callback enabled，reconciler `359→77→7→3/min`（<10 达标，~2min 内）。
- **永久修（Option 1，去旁路）**：4-agent 对抗式设计 workflow 裁定 + Codex 复核 → Redis 私网直绑 `172.16.0.85:6379`（保留 127.0.0.1），scaleout 直连（`REDIS_PORT 16379→6379`，PR #2010），退役代理。全程验证：RDB 备份+SAVE、ADD-not-replace、双路径 PONG、token/cursor 无丢、reconciler 持续 <10。

## 根因分析

- **表面原因**：scaleout derive 机队的 refresh 回调被禁用，所有完成丢给 reconciler。
- **根本原因**：scaleout 连 token-pool Redis 的临时代理白名单 IP 写错（`172.16.0.11` vs 真实 `172.16.0.212`）。代理是一段手搓的 transient systemd python TCP relay，本身是 token-pool 主干上的旁路。
- **系统性因素**：
  1. **跨机分布式系统的真因可以躲在"代码之外"**（服务器侧 ad-hoc 基建 / 未追溯的代理 / 被覆盖的有效环境变量）。纯代码 RCA——哪怕 4 个 agent 对抗式、达到 HIGH 置信——也看不见它。我的 Rank-1b 草稿（基于代码读 + 单机日志）把残留归因为 `completeAndNotify` 的 early-return guard arm，**方向性错误**。
  2. **"高置信"来自推理链的自洽，不等于"prod 已验证"**。早退 guard 的假说每一步代码都对，但它在 main box 上只占 ~1-2/min，根本不是 ~300/min 的来源。
  3. **静默路径无观测**：`completeAndNotify` 的 early-return 完全不打日志，导致 callback_nil 这种"整队禁用"长期隐形，只能靠 reconciler 兜底掩盖。
  4. **配置真值不在 `.env` 文件**：scaleout 有效 `REDIS_HOST/PORT` 来自 supervisor `environment=`（`config/refresh/...conf:41`），`.env` 文件里的 `127.0.0.1` 是被覆盖的假象。只读 `.env` 会得出错误结论。

## 教训

1. **跨机 / 分布式残留排查：观测先于代码 RCA，且必须覆盖所有 fleet。**
   - 场景：一个指标在多机/多 fleet 系统里降不下来，代码 RCA 给出"高置信"结论却修不动。
   - 规则：先给"静默路径"加 `reason=` 级观测（cheap、零行为变更）拿到真实分布，再动行为；且日志取证必须枚举每台机器（derive jobs 两台都跑，单机 grep 会得出"没 worker 碰过"的假象）。
   - 违反后果：基于自洽但错误的代码假说做行为变更（本例若按草稿放宽 guard，只影响 ~1-2/min，白改且给热路径加风险）。

2. **"配置真值"以进程有效环境（`/proc/<pid>/environ` / supervisor `environment=`）为准，不以 `.env` 文件为准。**
   - 场景：判断某服务连的是哪个 host/port/endpoint。
   - 规则：读 `/proc/<pid>/environ` 或 supervisor/systemd 注入的 `environment=`；`.env` 可能被覆盖。对齐"配置不许猜"。
   - 违反后果：照 `.env` 得出 `127.0.0.1` 的错误结论，错失"经代理连 16379"的真相（Codex 正是靠这条直觉点破）。

3. **手搓的 transient 旁路（代理/relay/tunnel）放在关键主干上 = 隐形单点故障；修复优先删旁路，回归既有惯例。**
   - 场景：发现某依赖经一个临时/手搓代理访问，而同类依赖（cost-model）是直连。
   - 规则：删旁路、走既有直连惯例（同时保证 SoT 可追溯），而不是把旁路持久化institutionalize。
   - 违反后果：旁路的配置错（白名单 IP）静默禁用整队功能数小时无人知；且 transient 不持久、不在 git、reboot 即失。

## 行动项

- [x] 真因修复并永久化（#2010 merged + Redis 私网直绑 + 退役代理 + Phase-0 观测保留）
- [ ] **live refresh-Redis compose 纳入 git SoT**（`/root/local-services/redis/docker-compose.yml` 不在仓库；repo 内 `ordo-backend/local-services/redis/` 是 mismatched dev 模板）
- [ ] **轮换 Redis `requirepass`**（live compose `command:` 里硬编码，pre-existing）
- [ ] 复盘"未达即回滚"预案：proxy 代理指标不应作为唯一 gate；业务 gate（积压/吞吐/parity）优先（本例机械回滚会 regress）

## 全局扩散建议（待用户确认）

1. **auto memory（已写）**：`reference_refresh_derive_scaleout.md` 记录 scaleout 机队 + 共享 token-pool Redis 架构 + SoT gap。
2. **建议补 `~/.claude/rules/debugging-discipline.md`**（或 pipeline-debug-protocol）一条："跨机系统的指标残留，先加静默路径 `reason=` 观测 + 枚举所有 fleet 取证，再动行为；代码 RCA 的'高置信'不等于 prod 验证。" —— 这条比现有"读实现不读符号名"更上一层（连实现都读对了，仍可能错，因为真因在代码之外）。**给建议，等确认。**
3. **建议补一条 feedback memory**："判断服务连接配置以 `/proc/environ`/supervisor environment= 为准，不以 `.env` 文件为准。" 是"配置不许猜"的具体化。**给建议，等确认。**
