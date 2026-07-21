# Postmortem: Derive video_detail zombie 排查 + 双 CAS 修复

**日期**: 2026-04-27
**项目**: ordo_ai (`/Users/qiansenmiao/Documents/Projects/ordo_ai`)
**严重程度**: 中（生产影响：8899 derive_job 长期卡死，但无数据丢失；修复涉及 race + 状态机改动）
**PR**: #982
**Spec**: `docs/superpowers/specs/2026-04-27_derive_video_detail_zombie_fix.md`

## 时间线

### 发现（用户 trigger）
- 用户问 "为什么 derive 的 rt 有 8899 个 pending"
- DB 实测：rt.ctrl pending=8899 全部 `dirty_flags=8 + step_video_detail_status='blocked'`，被 worker SQL `NOT (...)` 子句永久排除

### 第 1 轮根因尝试 — 假设 D（FinalizeFailedTask 缺口）
- 推断：result_job retry-exhausted 路径调 `FinalizeFailedTask` → `CheckAndCompleteBatch`，**不**调 `markVideoDetailStep*Tx`，所以 derive_job 不解锁
- **被量化推翻**：事故窗口 04-22~04-26 失败 task 仅 137（其中 lock-failed 6），远不能解释 7683 个僵尸 derive_job

### 第 2 轮根因尝试 — Codex 提的假设 B（Execute no-batch）
- 推断：`VideoDetailService.Execute` 命中 `hasActiveVideoDetailTasks` 或 backpressure 时返回 'blocked' 但**不建 batch**，无 callback 触发
- 量化证据：8849/8899 候选 creator alltime 没 video_detail task
- **被 retention 失真推翻**：用户提醒 `SYNC_TASK_RETENTION_DAYS=3`，事故时间 task 已被 retention 删除。"alltime 无 task" 是 Day-N 假象，不是事故时无 task

### 第 3 轮根因尝试 — vd_attempts race
- 推断：worker.go:248 IncrementStepAttempts 后 race + UPSERT reset attempts=0 + worker.go:258 overwrite step → 形成 dirty=8+blocked+vd_attempts=0
- **被字段污染推翻**：`CompleteJob` 在 success 路径会 reset 所有 attempts=0（`derive_job.go:511-515`）。我清理 9232 row 后 worker re-claim → CompleteJob → 字段已被污染。vd_attempts=0 不是事故时值

### 第 4 轮 — OSS 抽样实证（决定性证据）
- 用户决策："先停下来，搞清楚 root cause"
- OSS posts 文件**没有 retention 删除**，是唯一干净证据源
- 抽样 10 个候选 creator 的 `posts/v1/youtube/{prefix}/{creator_id}/shorts.json.gz`
- **关键发现**：post.UpdatedAt 分散在不同毫秒（`UpdatePostMetrics` per-post 写入特征）vs 同毫秒（`UpsertPosts` 批量写入特征）
- 70% 样本 D 路径（OSS 数据真写入了 → batch 完成 + callback 应被调用 + derive_job 仍卡）
- 30% 样本 B 路径（OSS 没写 → batch 未完成）

### 第 5 轮 — 双根因确认
- D 路径：worker.go:247/258 无条件 overwrite step → 覆盖 callback 已写的 'success'
- B 路径：eligibility NOT 子句永久排除 + 无 callback 自救

### 修复方案演进
1. **第一版（被自我否定）**：区分 with-batch / no-batch，新增 status enum，分裂 'blocked' 语义 → 用户问 "符合简单可靠原则吗" 触发自我批评，发现过度工程
2. **第二版（用户提示）**：删 NOT 子句 + 单 CAS（worker.go:258）→ Codex review 抓到不充分（claim → worker.go:247 间还有 race window）
3. **第三版（Codex 修正）**：双 CAS（247 + 258）+ 删 NOT 子句 + 同步删 monitor SQL NOT
4. **Phase 5.5 adversarial blocker（最终）**：Codex 抓到 ABA — `ClearExpiredLocks` 重置 status='running'→'pending' 但**不重置** `step_video_detail_status='running'`，下个 worker `TryStart` 永远命中不了 → 新永久卡形态。修复：扩展 `ClearExpiredLocks` SQL 重置 stale step。

### 部署 + 生产验证
- 16:13 UTC 部署 prod (10 program) + refresh (6 program)
- T+5min: zombies 400（从 448 降，但仍有新形成）
- T+30min: zombies 441 + bulk.heavy active 6651（worker 一次性 re-claim 4435 个旧 row 触发的 catch-up）
- T+1.5h: zombies 63 + bulk.heavy 883（消化 86%）
- T+2.5h: 真 zombie = **0**（全部 `dirty=8+blocked` row 都在 5min 内 in-flight，无长期卡死）

## 根因分析

### 表面原因
worker.go:247/258 无条件 UPDATE step_video_detail_status，会覆盖外部 callback 已写的 'success'/'failed'；eligibility NOT 子句永久排除 dirty=8+blocked + dirty&~8=0 的 row，没有 reaper。

### 根本原因
状态机设计假设了"`step='blocked'` 必有 actor 来调 markStep 解锁"，但现实中至少 4 条路径让 markStep 不生效或被 worker overwrite：
1. callback 在 worker.go:247-258 之间发生 → 被 overwrite
2. callback 在 claim → worker.go:247 之间发生 → 被 worker.go:247 改回 'running' 后 worker.go:258 改 'blocked'
3. ClearExpiredLocks 不重置 step → ABA double-claim
4. Execute() no-batch 路径根本无 batch 也就无 callback

NOT 子句把"等 callback"误当成"必有 callback"假设，**永久排除**而不是"短期排除 + 超时 fall-through"。

### 系统性因素

1. **monitor SQL 没区分 in-flight vs 卡死**：用 `dirty=8+blocked` 计数会把"瞬态等 callback"也算成 zombie，导致 canary 期间数字波动严重，难判断修复效果
2. **数据污染意识缺失**：CompleteJob reset attempts、retention 删 task、清理操作覆盖字段——这些都是 Day-N 数据陷阱，但我前 3 轮根因都直接信了 SQL 数字
3. **修复副作用没事先沟通**：删 NOT 子句让 4435 个历史 row 集中复活，bulk.heavy 一次性 catch-up，部署后 zombies 数字不立刻好看——这点应该在 PR description / spec 里说清楚
4. **adversarial review 的真实价值**：standard Codex review 给 LGTM 后才发现 ABA blocker。这次的 5 个 challenge 抓到 1 个 P0 blocker，证明 race / 状态机变更必须强制 adversarial。
5. **OSS 是唯一未污染证据源**：DB 字段会被各种路径污染，**对象存储数据不会**。事故 N 天后排查应优先 OSS / 不变 artifact

## 教训

### 教训 1：监控 SQL 必须加 age 过滤区分 in-flight vs 卡死

**规则**：任何"等异步回调"语义的状态字段，监控 SQL 必须加 `updated_at < NOW() - INTERVAL X` 过滤，把"瞬态等回调"和"长期卡死"分开计数。

**适用场景**：状态机里有"等外部 actor 解锁"的中间态（如 'blocked', 'pending callback', 'awaiting result'）。

**违反后果**：
- canary 期间数字剧烈波动（瞬态进入 + callback 解锁），难判断修复有效
- 误判正常流量为 backlog，触发不必要的回滚
- 浪费多轮 checkpoint 时间在"为什么数字回升"上

本次具体表现：T+30min zombies=441，T+1.5h=63，T+2.5h=132 — 数字波动巨大，但加上 age 过滤后 T+2.5h 真 zombie=0，立刻清晰。

### 教训 2：DB 字段是被污染的，OSS / 对象存储是干净的

**规则**：事故 N 天后做根因排查时，先列出每个 DB 字段的 writer 和"清理路径"（retention、reset、cleanup）。如果字段会被路径污染，**不能用它反推事故时状态**。优先用对象存储 / 不可变 artifact / 时间戳 trail 作证据。

**适用场景**：事故已过 1+ 天，原始事故时 DB 状态已被后续操作覆盖。

**违反后果**：基于污染字段下错根因，浪费多轮排查时间。

本次具体表现：3 轮错误根因都基于被污染的字段（task retention 删了 / CompleteJob reset 了 / batch retention 删了）。直到用户提示我才意识到。最后切到 OSS posts.json.gz 的 UpdatedAt 才拿到决定性证据。

### 教训 3：状态机/race 改动必须强制 adversarial review

**规则**：任何涉及 CAS、状态机转换、async callback 协调的改动，标准 review LGTM 后**必须**追加 adversarial review。adversarial 重点不是 verify 实现正确，而是 challenge 设计假设：假设最坏情况（lease 过期、进程崩溃、消息重排、并发同 row 多 worker），找会让修复失效的路径。

**适用场景**：CAS / race / 状态机 / 锁 / 分布式协议 / 异步回调协调。

**违反后果**：标准 review 只看 diff 不挑战设计假设，会漏掉"修复制造新永久卡形态"这类问题。

本次具体表现：Phase 5 Codex review 给 LGTM；Phase 5.5 adversarial 5 个 challenge 抓到 ABA blocker（ClearExpiredLocks 不重置 stale step）。如果跳过 5.5，PR merge 后会在生产**新形态卡死** dirty=8+step='running' 的 row。

### 教训 4：删除 eligibility 排除前必须预估"复活流量"副作用

**规则**：修复涉及"删除 worker SQL 的排除条件 / 让历史卡住的 row 重新可见"时，必须预估这批 row 集中重试会触发的下游流量峰值（爬虫 / API / 数据库 写入），并在 PR description 写清"部署后 X 小时内会有一次性 catch-up，期间监控数字会先涨后落"。

**适用场景**：reaper 上线 / 排除条件移除 / 历史数据集中重处理。

**违反后果**：部署后下游瞬时积压、监控告警、维护人员误判修复失败、浪费多轮 checkpoint 解释"为什么数字在涨"。

本次具体表现：删 NOT 子句让 4435 个旧 zombie 集中复活，每个创建 10 task → 4 万多个新爬虫任务砸 bulk.heavy 队列。canary 期间需要解释"修复在工作但 zombies 数字回升"，浪费 multiple turns。

## 行动项

- [ ] 给 PR #982 description 补一个 "Monitor SQL 应该加 age filter" 的 follow-up note
- [ ] 修复 `.tasks/2026-04-27_derive_zombie_canary_runner.sh` 路径 bug（`../..` → `..`）
- [x] 已写入本 postmortem 存档
- [ ] 是否要把"事故 N 天后排查必读 OSS / artifact 优先"加入 `pipeline-debug-protocol` skill — 待用户确认
- [ ] 是否要把"删 eligibility 排除条件"列入"预估 catch-up 副作用"的 spec checklist — 待用户确认
- [ ] 是否要给 `codex-driven-dev` Phase 5.5 adversarial review 触发条件加 "状态机/CAS/race 强制" — 待用户确认（当前是 list 之一不是强制）
