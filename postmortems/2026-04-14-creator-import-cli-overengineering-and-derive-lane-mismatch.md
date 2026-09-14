# Postmortem: Creator-Import CLI 过度工程 + Derive Lane 跨机错配

**日期**: 2026-04-14
**项目**: ordo-backend (`/Users/qiansenmiao/Documents/Projects/ordo_ai_main`)
**严重程度**: 中（无生产故障，但浪费~一晚开发+排查时间，并暴露了一个潜伏的跨机配置错位）

## 时间线

### 阶段 1（前一晚）— Spec & 实现 PR #793

- 用户原始诉求："不定期手动从 CSV 导入达人 + 触发 enrich + 让其在 DashVector 可搜"
- 走 codex-driven-dev：Codex 写 spec → Codex 写 plan → Claude Code 实现 → Codex review
- Spec 为"未来 GUI 上传页后端"做了前瞻性设计（D9 trusted columns、verify 双阶段等）
- 实现产出 ~1500 行 Go：parser / client / progress / runner / **verify** / cmd/creator-import/main + 完整测试
- PR #793 merge 上线

### 阶段 2 — 第一波 bug 大发现（凌晨）

- **5 row canary** 通过
- **200 row canary** 全部 verify=pending → 发现 Bug #4：DashVector 探针没前置 `https://`，URL parse 失败 → PR #794 修复
- **CA 全量 5,351 行 @ 3 RPS** 启动 → YouTube 74% 失败率 → 用户决断 "kill 并立刻调查"
- 排查中发现 verify.go 一连串 bug：
  - Bug #1: progress.Lookup race（mutex 缺失，PR #793 内修）
  - Bug #2: Summary.Failed double-count（PR #793 内修）
  - Bug #3: dedup-key vs MD5 PK 混淆，verify 永远查不到 creator（PR #793 内修）
  - Bug #5: `JSON_LENGTH(tags)` 遇 NULL 扫到 Go int 炸掉 → PR #796 修复

### 阶段 3 — Recovery + 大反转

- 提取 1683 个 failed enrichment_jobs → 1 RPS retry
- 跑完后 verify 报告 **92% failed**，超出我对"队列过载"的预期
- 抽样查 ordo_creators 发现：所谓"failed"的 1518 个 creator **都有完整 tags + alias + followers**
- 写 30 行 Python 直接查 DashVector → **5,323 / 5,351 (99.5%) 实际可搜**
- 暴露 **Bug B（架构级）**：verify.go 第 239 行 `if job.Status == "failed" { return failed }` 短路，不查 creator 真实状态 → 1518 个 false negative
- 这一刻意识到："verify.go 在 CLI 内复刻 DashVector + ordo_creators 的判定逻辑，注定脱节"

### 阶段 4 — 非 CA 全量 + 决策反转

- 派 2 个 teammate agent 并行：ca-analyzer 分析 5,351 CA 分布；non-ca-importer 启动剩余 16,727 行
- 非 CA 全程 1 RPS clean run → 4h 36min → DashVector 99.3% 可搜
- ca-analyzer 报告红旗：DB 里只有 559 个 creator country=CA（10.5%）
- 用户当晚决定："country 还是要先通过 csv 写入" → 手动 SQL UPDATE 4770 行 country='CA' + DashVector resync（备份在 `/tmp/ca_country_backup.csv`）
- **几小时后**用户反转决定："不用 csv 里的 country，还是保留由我们爬取的来源提供"
- 全量回滚 4770 行 + 第二次 DashVector resync → 100% 还原

### 阶段 5 — 砍掉 verify.go（PR #798）

- 决定：verify.go 整层删除，CLI 只做 CSV → HTTP submit
- net diff: -1087 / +33 行（8 文件）
- Codex review **抓到 blocker**：旧 progress.json 里 `state="verified"` 字符串行不再被 producer loop 跳过，会被重复提交到 crawler
- 修复：3-if 改成 switch + 显式 default-skip 分支 + 2 个 sqlmock 回归测试
- Codex 复审 LGTM → merge

### 阶段 6 — 真根因 derive 超时排查（次日早晨）

- 用户 follow up："那 derive 超时是真的还是某一步导致"
- 系统化 debugging：
  - 读 enrichment_derive.go 代码：`deriveMaxWait = 120s`，YT 走两道 gate（derive_jobs.status + checkYouTubeVideoDetailComplete）
  - 数据查 1310 个 timed-out derive_jobs：**706 (54%) 在我们 enrichment 之前 >24h 创建**，0 个是 enrichment 后创建的
  - 全队列 04-13 17:00 UTC 时刻：4829 pending derive_jobs，10 worker 处理深度 ~30min-2h
  - **94% 在窗口内完成的 derive 排队 >24h** → 长期 backlog 状态
- 用户："derive 我记得是有优先级的？先确定下 derive 现在是只在 refresh 机器上跑，还是 prod 上也有"
- **核弹级发现**：
  - prod 有 3 个 lane group：rt.enrichment / rt.ctrl / rt.heavy
  - refresh 配的是 `DERIVE_WORKER_LANES=bulk.ctrl,bulk.heavy`
  - **refresh 上的 enrichment 产出 video_detail derive_jobs → lane=rt.heavy**
  - **refresh 的 10 个 worker 永远不 claim rt.heavy** → 这些 row 只能等 **prod 上 2 个 ordo-derived-worker-rt-heavy** 跨 RDS 处理
  - 验证：1310 个 timed-out 的 derive_jobs 中 **2570/2620 (98%) 在 lane=rt.heavy**

### 阶段 7 — Prod 容量扩容 PR #802

- 决策：保持 refresh bulk-only（产品要求隔离），扩 prod rt.heavy
- 改 `config/prod/ordo-derived-worker.conf` numprocs `2 → 4`
- Codex review **抓到两个 finding**：
  - **数学错**：`numprocs` 是 supervisor proc 数，每个 proc 内还有 `DERIVED_WORKER_COUNT=10` 个 goroutine worker。实际并发是 **20 → 40**，不是我说的 "2 → 4"
  - **deploy 命令不安全**：`git pull origin main` 不强制 main + ff-only
- 修复 PR body → Codex LGTM → merge → deploy → 4 RUNNING 验证通过

## 根因分析

### 1. 表面原因

- **CA 导入 enrichment 大量超时**：`waitForDeriveSuccess` 等 120s 拿不到 derive_jobs.status='success'
- **verify.go 5+ bug**：每次 canary 跑都翻新石头

### 2. 根本原因

#### A. CSV Import CLI 严重过度工程
- 任务实际是"一次性手动补达人"，但 spec 写成"产品化 CLI + 未来 GUI 后端"
- 1500 行 Go + 全套测试 + 5 个 bug + 1 个架构级 Bug B
- 关键判断错误：**verify 应该在管道外做（DashVector + ordo_creators 是真值），不应该在 CLI 内复刻**
- 用户最后画的口子：CLI 只做 CSV→HTTP submit，verification 用 30 行 Python 独立查（事实证明这是最可靠的）

#### B. Derive lane 跨机静默契约
- prod 设计了 4 个 lane（rt.ctrl/rt.heavy/rt.enrichment/bulk.*）做 RT vs Bulk 分流
- prod worker 配 `DERIVE_WORKER_LANES=rt.enrichment,rt.ctrl,rt.heavy`（吃 RT）
- refresh worker 配 `DERIVE_WORKER_LANES=bulk.ctrl,bulk.heavy`（吃 Bulk）
- 设计假设：refresh 只跑"bulk 数据刷新"，不跑实时 enrichment
- **但 refresh 上 data-center-control 也响应 `/api/v1/crawler/channel`**（CLI 走的就是这个端点），enrichment 在 refresh 进程内运行
- enrichment → video_detail → lane=rt.heavy → 写到共享 RDS → **refresh 本机 worker 不 claim** → 只能等 prod 远程处理
- prod rt.heavy 只 2 supervisor proc × 10 内部 worker = 20 actual worker，扛不住 batch import burst

#### C. `deriveMaxWait=120s` 是同步等异步的脆弱契约
- enrichment_service 同步 polling derive_jobs.status，硬编码 120s 超时
- 但 derive 是共享异步队列，FIFO 处理，任何时刻有 5K+ pending 老 job
- 当 enrichment 来 polling 时，目标 row 在队列后段，120s 内根本轮不到
- "timeout 不是 worker 慢，是排队晚"——和 worker 单 job 处理时间无关

### 3. 系统性因素

- **codex-driven-dev 的 spec 阶段缺一道"成本/收益审视"**：Codex 按 spec 完整产出，没有反问"这真的需要 1500 行吗"。一次性任务和产品化 feature 应该有不同模板。
- **CLI 与上游服务的"信任边界"模糊**：把上游服务的状态判定逻辑搬进 CLI，是常见的 over-eager 错误。任何"我帮你判断 X 是否成功"的本地实现，都应该先问"上游难道没有真值源吗"。
- **跨机配置依赖没有 contract 文档**：refresh 写 rt.heavy lane 依赖 prod worker 处理，这种 cross-machine implicit contract 在任何 config diff / lane 变更里都不会被发现，直到 batch import 把它打爆。
- **Codex review 的两条 finding 都是我的"想当然"**：(1) 老 progress 文件兼容（我在 PR body 信誓旦旦说兼容，没验证）；(2) numprocs 数学（我没读 cmd/derived-worker/main.go 的 DERIVED_WORKER_COUNT 处理，凭经验 estimate）。这两条都是**一行命令就能查证的事实，我跳过了**。

## 教训

### 教训 1: 一次性任务用一次性代码，不要"产品化预投资"

**规则**：当任务本质是一次性手动操作时（"今晚补这批数据"），即使将来"可能"会做产品化版本，也要先用最薄的脚本跑通，不要先写完整 CLI/服务。

**适用场景**：
- 数据回填、补漏、迁移（一次性 by 定义）
- "先帮我手动跑一下 X，将来要做成 Y"——先做 X，等真的要做 Y 时再说
- 任何看似 "一次的" task

**违反后果**：
- 产出的"工程化"代码包含大量未经真实需求验证的设计决策（D9 trusted columns、verify 双阶段、--retry-failed 多模式...）
- 每个未经验证的设计点都成为 bug 温床（5 个 verify 相关 bug）
- 修 bug 的时间 >> 完成原任务的时间
- 最后还是要回头删（PR #798 -1054 行）

**判断启发**：
- 如果"一次性脚本"里有 `--verify-after`、`--dry-run`、状态机、可测试接口抽象——超工程信号
- 30 行 Python > 1500 行 Go，**对一次性任务而言**

### 教训 2: 不要在 client 里复刻 source-of-truth 的判定逻辑

**规则**：当外部系统是某个事实的真值源时（DashVector "is creator searchable"、ordo_creators "is data populated"），客户端代码不应该"自己计算一遍"，而应该直接查源头。

**适用场景**：
- 验证类代码（verify、check、is-X-ready）
- 任何 "我们这边判断一下 X 状态" 的本地实现
- 凡是真值在别处的事实

**违反后果**：
- verify.go 重新实现了一遍 "是否在 DashVector 可搜" 的判断逻辑
- 结果该判断逻辑和真实 DashVector 状态脱节（Bug B 就是 enrichment_jobs.status 撒谎，而 ordo_creators + DashVector 才是真的）
- 误判率 30% (1518 / 5351)，比直接查 DashVector 多绕了 5 个 bug 的弯路
- 最后还是要写 30 行 Python 直接查源头

**判断启发**：
- 写 verify/check 代码前，先问："X 的权威来源在哪？我能直接 query 那个吗？"
- 如果上游是"submit + async 处理 + 异步落库"模型，CLI 没有理由实现"这个 submit 现在到哪一步了"——直接问最终落地的存储

### 教训 3: 跨机隐式契约必须显式化（contract over convention）

**规则**：任何"refresh 写 X，靠 prod 来处理 X" 这种跨机依赖，都必须在 conf/spec 中显式标注，不能依赖"大家都知道这么配"。

**适用场景**：
- 多机器共享同一个数据库/队列时
- 任何 lane / shard / partition 的 ownership 划分
- env 变量驱动的行为分流

**违反后果**：
- refresh 上的 enrichment 写入 rt.heavy lane → 本机 worker 不 claim → 静默依赖 prod worker → batch import 时打爆 prod 那 2 个 worker
- 故障表象（enrichment timeout）远离根因（lane ownership 错配）
- 排查路径：120s timeout → "1 RPS 太快？" → "代码 bug？" → "队列积压？" → 最后才是 "lane 配置不匹配"——绕了一晚上

**判断启发**：
- 当看到 supervisor conf / .env 里有 lane / queue / shard 类的过滤参数时，问："谁写这些数据？谁读？写入方和读入方在不在同一机器上？"
- 如果两台机器共享 RDS 但 worker 配置不同，画一张 "lane × machine" 矩阵，确认每个 (lane, write-source) 都有对应的 reader

### 教训 4: Codex review 的"想当然"是最贵的错误，不要为了快跳过事实查证

**规则**：在写 PR body / 设计文档时，任何"X 是 Y"的断言都必须有可执行命令验证过（grep 代码 / 查 schema / 跑测试），不能凭印象。

**适用场景**：
- PR description 里的兼容性声明
- 容量/性能数学
- 部署步骤的"安全性"假设

**违反后果**：
- PR #798 我说"backward compat: 旧 progress.json 兼容"——没验证，被 Codex 当场抓到 blocker（state="verified" 行会被重复提交）
- PR #802 我算"2 → 4 worker 容量"——没读 cmd/derived-worker/main.go 的 DERIVED_WORKER_COUNT 处理，被 Codex 抓到实际是 20 → 40
- 这两次都是 "一行 grep / 读 30 行代码就能查清"的事实
- Codex 抓 blocker 是好事，但反过来：如果某个 PR 没人 review（自己 merge），这种"想当然"会直接挂线上

**判断启发**：
- 在 PR body 写"X is Y" 之前，**先在 terminal 跑那条 grep / 那次 wc / 那个 SELECT**
- 部署命令前先确认"在 main 分支吗？git pull 是 ff-only 吗？"——不要写 `git pull origin main`，要写 `git checkout main && git pull --ff-only origin main`
- 容量数学涉及 numprocs / threads / workers / connections 时，必须读源代码确认每层语义，不要只看 supervisor conf

### 教训 5: 同步等异步的契约要么参数化，要么干掉

**规则**：当 A 同步 polling 等 B 完成、B 是共享异步队列时，A 的超时参数必须可配置 + 能被监控调整，否则就要重新设计成 A 完全异步。

**适用场景**：
- enrichment_service.waitForDeriveSuccess(120s)
- 任何 "调用方等结果" + "处理方共享队列" 的双层结构
- request-response over async backend

**违反后果**：
- 120s 是 hardcoded constant，没有任何环境变量、Config、调参手段
- 队列积压时所有 enrichment 集体超时
- 修复需要改代码 + 部署，而不是改配置
- 故障无法在不重启服务的情况下缓解

**判断启发**：
- 任何 hardcoded timeout 都是技术债。看到 `var deriveMaxWait = 120 * time.Second` 应该立刻问"这是从哪个 SLO 得出的？运维有手段调它吗？"
- 长期方案是把 enrichment 改成异步：submit 立即返回 enrichment_id，前端/调用方轮询；后台 worker 自己回写状态。但这是大改造。
- 短期方案是参数化超时 + 加监控，至少出问题时能 hotfix 配置。

## 行动项

### 已完成（本次 session 内）
- [x] PR #794 — DashVector scheme prepend
- [x] PR #796 — JSON_LENGTH NULL scan IFNULL
- [x] PR #798 — 砍掉 verify.go 整层 + legacy verified state 跳过
- [x] PR #802 — prod rt.heavy worker 2→4（实际 20→40 actual）
- [x] CA recovery 闭环（5,323 / 5,351 = 99.5% 可搜）
- [x] 非 CA 全量 import（16,603 / 16,727 = 99.3% 可搜）

### 待跟进（不在本次 session）
- [ ] **下次 batch import 时验证**：观察 prod rt.heavy 4 worker 是否消化得动 burst。如果 timeout 率仍高，考虑 2 → 6 supervisor proc（60 actual workers）
- [ ] **enrichment_service.waitForDeriveSuccess 参数化**：把 hardcoded 120s 改成 `ENRICHMENT_DERIVE_MAX_WAIT_SECONDS` env 变量，至少给运维一个手段
- [ ] **lane × machine 矩阵文档**：在 `docs/data-center/` 加一份 lane ownership 矩阵，说明每个 lane 在每台机器上是 producer / consumer / both，避免下次有人 silent 配错
- [ ] **创建 reference memory**：把"derive 队列 + lane 系统"写成一份排查手册，下次不用从头摸 enrichment_derive.go + supervisor conf + .env

### 可选（如果以后还要做 batch import）
- [ ] **建立标准 batch import 流程**：(1) 30 行 Python 脚本调 crawler/channel API；(2) post-import 用独立 Python 查 DashVector + ordo_creators 出报告。**不要再写 Go CLI 给一次性任务**

## 是否需要全局更新

### 建议加入 auto memory（feedback 类型）

**Memory 1 — 一次性任务的工具选择**
- name: `csv-import-prefer-script`
- description: When user asks for a "one-off" data import/backfill, default to a 30-line script (Python/bash), not a productized CLI. Productize only when the same task recurs ≥3 times AND has stable interface requirements.
- type: feedback
- 内容：
  - 规则：一次性数据补漏/导入任务用最薄的脚本（30 行 Python 调 HTTP），不要起新的 cmd/ Go 项目
  - Why: 2026-04-14 写了 1500 行 Go CLI 做一次性 CA 导入，verify.go 一层就有 5+ bug，最后整层删除（PR #798 -1054 行）。同样的事 30 行 Python 一次跑通。
  - How to apply: 看到"补一下数据"、"导入一批"、"一次性"等关键词时，先问"这事一年内会再跑吗？"。≤2 次就用脚本，≥3 次再考虑 CLI

**Memory 2 — verify 不要在 client 内重新实现**
- name: `client-verify-source-of-truth`
- description: When writing verification/check logic in CLIs or clients, query the source-of-truth system (DashVector, RDS) directly, never reimplement state-judgment in client code. Especially when the client lives outside the system being verified.
- type: feedback
- 内容：
  - 规则：CLI/client 不要复刻上游系统的"是否完成/可用"判定逻辑。直接查上游存储/索引拿真值
  - Why: 2026-04-14 verify.go 在 CLI 内重新实现"是否在 DashVector 可搜"判定，结果和真实 DashVector 状态脱节产生 1518 个 false negative，并连环踩 5 个 bug。最后用 30 行 Python 直接查 DashVector 反而是最可靠的
  - How to apply: 写 verify/check 代码前先问"X 的权威来源在哪？我能直接 query 那个吗？"。能直接查的别本地算

**Memory 3 — PR body 的事实断言必须验证过**
- name: `pr-body-claims-need-verification`
- description: Before writing any "X is Y" claim in a PR description (backward compat, capacity math, deploy safety), run the actual command (grep/wc/SELECT/code read) to verify the claim. Never write claims based on intuition.
- type: feedback
- 内容：
  - 规则：PR body 里任何事实断言（兼容性 / 容量数学 / 部署步骤）都必须有 terminal 命令验证过，不能凭印象
  - Why: 2026-04-14 PR #798 我自信声明"backward compat"，被 Codex 抓到 legacy state="verified" 行会被重复提交。PR #802 我算 numprocs 2→4，没读源代码确认 DERIVED_WORKER_COUNT=10 per-process，实际是 20→40。两次都是一行 grep 能查清的事实
  - How to apply: 写 PR body 时，每写一个"X is Y"前停下来跑那条命令。容量数学涉及 numprocs/threads/workers 必须读源码

### 建议加入 reference memory

**Memory 4 — derive 队列 + lane 系统排查手册**
- name: `derive-queue-and-lane-system`
- description: How the data-center derive system is organized: `ordo_creator_derive_jobs` table, lane field, content_type field, multi-machine worker pool, lane ownership across prod/refresh.
- type: reference
- 内容：
  - **enrichment 同步等待**：`enrichment_service.waitForDeriveSuccess` polls `derive_jobs WHERE creator_id=? AND content_type='videos'` with hardcoded `deriveMaxWait=120s` (`data-center/service/enrichment_derive.go:11`). YouTube 还有第二道 `checkYouTubeVideoDetailComplete` 闸（同时 check videos+shorts video_detail tasks）
  - **lane 路由**：`video_detail_service.go:648` 调 `EnqueueDeriveJobImmediateEnrichmentTx(tx, ..., task.Lane, ...)`，derive_jobs 继承上游 sync_task 的 lane。enrichment-driven video_detail → traffic=rt + workload=heavy → **lane=rt.heavy**
  - **lane × machine 矩阵 (2026-04-14)**：
    - prod: `DERIVE_WORKER_LANES=rt.enrichment,rt.ctrl,rt.heavy`，3 个 group：rt-enrichment(3 procs) / rt-ctrl(3 procs) / rt-heavy(2→4 procs after PR #802)
    - refresh: `DERIVE_WORKER_LANES=bulk.ctrl,bulk.heavy`，1 个 group(10 procs)
    - **refresh 写 rt.* lane 数据，但本机 worker 不 claim**，依赖 prod worker 跨 RDS 处理
  - **每个 supervisor proc 内启动 `DERIVED_WORKER_COUNT=10` 个 goroutine worker**（cap 50，cmd/derived-worker/main.go:206）。所以"4 supervisor procs"=40 实际 worker
  - **lane upsert 行为**：`derive_job.go:77` 的 `lane = IF(status IN ('success','failed') OR LEFT(VALUES(lane),2)='rt', VALUES(lane), lane)` — RT 前缀的新 insert 会 OVERWRITE 现有 lane
  - **排查路径**：当看到 enrichment "derive job timed out or missing" 时，第一件事查 `SELECT lane, COUNT(*) FROM ordo_creator_derive_jobs WHERE creator_id IN (...) GROUP BY lane`，确认本地 worker 是否处理那个 lane

### 不需要扩散

- "不要把临时实验开关留下"（CLAUDE.md 已有）
- "禁止直接修改服务器文件"（safety.md 已有）
- "READONLY 查 prod"（ai-ops.md 已有）

这些规则今晚都执行得不错，没违反。
