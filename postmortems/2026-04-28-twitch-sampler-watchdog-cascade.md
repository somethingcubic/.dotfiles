# Postmortem: Twitch Sampler Watchdog Cascade — 8 PR / 9h 救火 + UX 改造

**日期**: 2026-04-28
**项目**: ordo_ai_dev (`/Users/qiansenmiao/Documents/Projects/ordo_ai_dev`)
**严重程度**: 中（Session path 写入中断 ~43h，但实时口径未影响；操作员被噪音 Alert 持续骚扰）

---

## 时间线

### 起点（4-26 ~ 4-28 早晨）

- 4-24：RDS 100% CPU 事故，sampler 一轮 20min + 119996 scalar errors，FSM 进 degraded_open 后**无法自动恢复**（line 460 spec 退出条件 + 累计错误率累计窗口设计），需人工 restart sampler
- 4-26 起：sampler 反复出现 round_duration 10-19min 慢轮（凌晨 RDS 抖动期）→ watchdog `RuleRoundDurationHigh` 累计 → engage kill_switch（24h TTL）→ session path skip 持续 ~43h
- 4-27 凌晨：用户问"为什么 critical 报警"——我开始排查

### 4-27（前期 PR）

- **PR #975**：FSM `scalarDegradedLocked` 累计错误率 → 逐轮判定（修 4-24 不能自恢复 bug）
- **PR #974**：scalar path 单行 SQL → batch upsert（1000 行/SQL；二次 bug：batch 失败 errorCount 按 batch 计被 Codex 抓到稀释 FSM，改成按 row 计）
- **PR #977**：alerter `staleTimeoutCloseRule` cumulative sum across window → window-internal delta（修永久 fire bug）

### 4-28 上午（核心事件日）

- **05:49 + 06:19 CST**：sampler session_path 两轮各 14min overrun（active_gauge ~30k × 单行 SQL × 4 worker × RDS jitter 100ms/row）
- **06:35**：watchdog `RuleSessionPathOverrun` 累计 ≥ 2 → 自动 engage kill_switch
- **10:46**：用户问"为啥又 critical"——我开始救火
  - 错误判断 #1：以为 PR #974 修了所有问题；实际只修了 scalar，session 是同样结构问题（**没读 session_path.go 实现**）
- **11-12 CST**：发现 session 单行模式 → PR #1008（env-only concurrency 4→16 临时对冲）
  - 漏掉的部署步骤：忘记 `cp .env.refresh .env`，第一次 restart sampler 仍读旧值，verify 启动日志才发现
- **12:47**：写 PR #1014 spec（session_path batch）
  - **错误 #2**：spec 里凭印象写死链：`engageKillSwitch` / `scalar.go` / `cache.go` / `reconciler.go` 等多个不存在的 file/function 名
- **派 worker 实施 PR #1014**：Codex 抓 blocker（缺 SELECT FOR UPDATE 引入并发 race）→ 修复
- **13:08**：execute Option B（restart sampler 让 FSM 跳出 degraded_open recovery latency）
  - 期间用户问"为什么 worker bump 完没生效"→ 我前面 cp .env 漏掉，被用户实际抓到才补 cp
- **13:45**：新 sampler 启动，PR #1014 batch path 第一次真跑
  - duration 5m53s, session_path_duration_ms=62s（restart 副作用 32440 stale_timeout 处理量）
- **14:23**：飞书 fire `stale_timeout_close_burst` warning count=32440
  - **错误 #3（最严重）**：我看到 bp_reason=scalar_degraded 立刻推 "FSM 在 degraded_open recoverStreak<2"，**没读全局代码 + 没看 session_path_state metric 状态码定义**
  - 用户怒拉我："你重新加载 CLAUDE.md，然后用 root cause 来告诉我"
  - 老老实实按 pipeline-debug-protocol：4 个假说 + 证伪测试 + Codex 协作 + spec 引用 → 真 root cause = FSM 设计的 RecoverRounds + CooldownRounds 共 4 round latency（by design）

### 4-28 下午（UX 改造）

- 用户："那报警的信息就要换成可读的信息了，你现在发的那些报警我也看不懂"
- **PR #1022**：飞书消息中文化 + AI runbook prompt（10 条规则 + 5 fingerprint variants）
  - Codex 4 轮 review 都抓到 worker 漏洞：①AI prompt 里凭印象写的死链 ②文案 lockdown 是弱 substring ③header 格式不匹配 spec ④spec.md 自己有 trailing whitespace + 死链漏改 + prompt body 没 lockdown
- **PR #1025**：AI prompt host 从 os.Hostname() (ECS instance ID) 改成 OpsSSHAlias
  - 用户实际收到飞书消息后才抓到 host=iZt4n65pz9rippxkc9qphoZ → 复制 prompt 给 AI 就 dead-end
- **PR #1030**：AI prompt 折叠面板（v2 collapsible_panel）
  - 用户："不需要介入那就不用放下面那些排查的东东了吧？容易误会？"
  - Codex 抓 v2 schema 用 deprecated note element → 修

---

## 根因分析

### 表面原因
- Twitch sampler 两条独立写入路径（scalar + session）都是"4 worker × 单行 SQL × 33k+ 行" 结构性瓶颈
- alerter 多条规则有"sum across window" / "累计当 delta" 等设计 bug
- FSM 恢复 latency（4 round / 2h）跟 kill_switch DEL 的"立即生效"语义不匹配

### 根本原因（[推断]，基于代码 + spec 阅读）
1. **PR #974 时只看到 scalar 的瓶颈，没顺势检查 session 是不是同结构** —— 当时 session path 被 kill_switch block 没暴露问题
2. **spec v6.1 设计 backpressure FSM 时，把 "scalar degraded" 和 "manual kill switch" 都当成需要 RecoverRounds 验证的 degraded condition** —— 没区分"系统自身故障"vs"带外管理信号"
3. **alerter 多条 rule 把 sampler heartbeat 字段（cumulative counters）当 delta 求和** —— writer/reader 对同一字段的语义假设不一致

### 系统性因素（最重要）
1. **我凭印象写 spec 里的 file:line / function name 锚点**，没 grep 验证
   - 后果：worker 用 spec 当 ground truth，bug 链放大（Codex review 第 2 轮才抓到）
2. **看到陌生单位/数量级直接接受**："5 MB/s 是 sampler 引起的"——实际是 5 **Mbps**（差 8 倍单位错误）
   - 后果：error attribution 全错，幸亏 agent 调研抓出真凶 ordo-sync 跨区域调用
3. **看到一段代码就推论整个状态机行为**：bp_reason=scalar_degraded 推 FSM degraded_open recovery，没读 publishStateLocked 状态码映射
   - 后果：用户拉回 pipeline-debug-protocol 才纠回事实
4. **Worker self-evaluation 必偏乐观**：4 个 worker × 总共 13 轮 fix-on-fix，Codex 每轮都抓到新问题
   - 这是 CLAUDE.md "生产与验收分离" 的教科书证据
5. **UI 改动靠单元测试不够**：PR #1022 通过所有 lockdown test，但 AI prompt 实际渲染显示 ECS instance ID（os.Hostname() 在 ECS 上）—— 单测看不到这种"渲染数据来源"bug，**必须 e2e 真发一条消息看输出**

---

## 教训

### 教训 1：spec / 文档里写 file:line / function name 必须先 grep 验证

**规则**：写 spec 或 hand-off 文档里出现 `xxx.go:N` / `(funcName)` 形式的锚点时，**写完立即 grep 验证文件 + 函数名实际存在**。验证通过才能交给 worker / Codex / AI agent 当 ground truth。

**适用场景**：写 spec 文档、写 hand-off message、给 AI agent 发 prompt、写 PR 描述、写 postmortem 引用代码。

**违反后果**：bug 链放大——下游 worker 把死链照搬进生产代码，又把死链 prompt 渲染给操作员复制给新 AI session 形成 dead-end。

**机械化检查**：
```bash
# 给定一份 markdown，提取所有 .go 引用 + 函数名引用，逐一 grep
grep -oE '[a-zA-Z_/]+\.go(:[0-9]+)?|\([a-zA-Z_]+\)' spec.md | sort -u | while read ref; do
  # for .go path: ls / cat
  # for (funcName): grep -rn "func.*funcName" 
done
```

### 教训 2：陌生单位 / 数量级必须追问 "它实际测量什么"

**规则**：报告里数字没单位或单位写得模糊（"5 MB"、"100 ms" 不带说明），**第一反应是问"这是 byte/s 还是 bit/s？是 wall clock 还是 CPU 时间？是 cumulative 还是 per-round delta？"**——不要凭"应该是 X" 推论后续。

**适用场景**：性能数字、带宽数字、metric 数字、监控曲线、Aliyun CloudMonitor 字段。

**违反后果**：CLAUDE.md "禁止 pattern：单一数字铺整套理论"——我把 5 Mbps 当 5 MB/s 推 sampler Helix scan 是元凶，整个推理链全错。

**对照 4-22 教训**："received_at" 写入点不是 worker 是 ingester——同样问题：看符号名 / 看数字字面意思就下结论。

### 教训 3：UI/渲染类改动必须 e2e 真渲染验证

**规则**：涉及 "用户看到的输出"（飞书消息、Web UI、邮件、CLI 输出格式）的改动，单元测试只能覆盖结构，**不能验证渲染数据的来源是否正确**。必须做 e2e 真触发一次 + 看实际输出。

**适用场景**：飞书 / Slack / 邮件 / WebSocket 通知、Web UI、CLI 命令输出格式。

**违反后果**：PR #1022 通过 14 个 lockdown test 但 host 字段渲染 ECS instance ID（用户实际看到才抓到）——单测看不到 "用什么 source 填这个 placeholder" 的语义错误。

**机械化检查**：
- 给 worker prompt 时加："实施完成后，跑一次本地 dry-run（环境允许的话）/spawn 一个测试 event 让 notifier 真渲染输出到 stdout，把渲染结果贴到 PR description 让 review 看"
- E2E 验证不到（如飞书需要 webhook）：手动触发一条 fire event 后，让用户/同事在客户端实拍截图 review

---

## 行动项

- [ ] **更新 `~/.claude/rules/`** 加 "spec/handoff 锚点必须 grep 验证" 规则（候选见下面"全局更新建议"）
- [ ] **更新 `~/.claude/rules/`** 加 "陌生单位必须追问" 规则（候选见下面）
- [ ] **派 worker agent 模板加 "UI/渲染改动需 e2e dry-run"**：在 spec-driven-dev / codex-driven-dev skill 里加这条
- [ ] **创建 `docs/pipeline/data_pipeline_fact_map.md`** —— Codex 排查时抱怨 "MISSING"，CLAUDE.md 第 57 行明确要求先读这个 map。当前不存在 → 把 sampler / scalar / session 各组件的 writer / reader / 时间戳字段编进去
- [ ] **`reports/tech/20260427_twitch_live_sampler_overview.md`** 加一节 "FSM 恢复 latency 的设计权衡"——把今天 root cause 排查结论沉淀进文档
- [ ] **PR follow-up issue #1027** 处理：footer host alias / .env key / OpsSSHAlias 单测
- [ ] **24h soak**：观察今晚凌晨 4-9am CST 美国 prime time PR #1014 batch path 表现，明天复盘

---

## 全局更新建议（请用户确认）

### 建议 1：`~/.claude/rules/truth-directive.md` 追加 "锚点验证" 子节

```markdown
## 锚点引用必须 grep 验证（新增）

写 spec / hand-off message / PR description 等含有 `file.go:N` / `(funcName)` 形式
的代码锚点时：
- 写完 → 立即 grep / ls / cat 验证文件 + 函数名实际存在
- 没验证的锚点 → 标 [未验证] 或不写
- 把锚点交给 worker / AI agent 当 ground truth 前必须 100% verify

**违反后果**：bug 链放大——worker 把死链照搬进代码，AI agent 拿到死链 prompt 走 dead-end。
**典型场景**：写 spec、给 worker 发 brief、写 postmortem 引用代码。
```

### 建议 2：`~/.claude/CLAUDE.md` 第 64-67 行 "禁止 pattern" 列表追加：

```markdown
- **数字 / 单位看到要追问 "实际测量什么"**：5 MB/s vs 5 Mbps（差 8 倍）、cumulative vs delta、wall vs CPU。先问单位定义，再用数字推论。
```

### 建议 3：auto memory 写一条 feedback

```markdown
---
name: worker_self_eval_lossy_to_codex_review
description: Worker agent self-validation 必偏乐观，每个非 trivial PR 必须 Codex review，不要跳过
type: feedback
---

实践证据：2026-04-28 一天 8 个 PR，4 个 worker agent 共 13 轮 fix-on-fix，
Codex review 4 个 PR 总驳回 7 次，每次都抓到 worker 漏掉的真问题（死链 / 弱
guard / 半角全角符号 / v2 schema 弃用元素 / 渲染来源错误）。

**Why**: worker 自评只验证 build + 自己写的测试，不验证：
- spec drift（worker 把 spec 草稿里的死链照搬当 ground truth）
- 渲染数据来源语义（lockdown 测试覆盖结构不覆盖 source）
- 兼容性（v1/v2 schema 字段废弃）
- 边界条件（user 实际场景下的 race / latency）

**How to apply**:
- 中型偏重 PR（>100 行）必须 Codex review，不跳过省时间
- worker prompt 要求 "self-validate" 时不要相信，仍走 Codex
- 部署后用户实际验收（飞书消息、UI）算 final review
```

**仅存档不扩散**：行动项里很多是 "今天个案"，不是 generally applicable rule，单独 archive 即可。

请用户决定 1/2/3 哪些加进全局，哪些只存 postmortem。
