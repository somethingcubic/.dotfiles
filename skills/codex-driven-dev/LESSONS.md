# Codex-Driven Dev 实战教训

## Pane 选定（Phase 0 P0 教训）

0. **CODEX_PANE 不能跨 session / 跨 window / 跨 pwd 选**。即使列出来 7 个 codex pane，也不能凭"路径接近"或"列表第一个"挑——必须 orchestrator 自己 4 值（session / window / pane / pwd）的同 session + 同 window + 同 pwd 完全匹配。不匹配 → split 新建。教训：2026-05-11 凭直觉挑了 dev:1.1（cwd 是 ordo_ai 而我在 ordo_ai_main 工作），结果是别人正在用的 codex pane，差点污染上下文。
0.5. **auto suggestion 灰字 ≠ 非 idle**：codex CLI 输入框上方会显示"Run /review on my current changes"等灰色 auto suggestion——这是 CLI 的智能提示，不是正在执行的任务。判断 idle **只看进程是否在跑 / 任务是否在执行**，看灰字会误判。
0.6. **查自己 pane 必须用 `$TMUX_PANE` 或 PPID 反查，绝不用 `tmux display-message -p`**。后者返回当前 tmux client 的 active pane——多 client 场景下（用户在另一个 client 看着别的 pane）会返回别人的 pane，不是 Claude Code 进程所在 pane。正确方式：`echo $TMUX_PANE`（如 `%14`），再 `tmux list-panes -a -F '#{pane_id} #{session_name}:#{window_index}.#{pane_index} pid=#{pane_pid} pwd=#{pane_current_path}' | grep $TMUX_PANE` 反查 session:window.pane + pwd。教训：2026-05-13 用 `tmux display-message` 拿到 poc:5.1（别人的 active pane），按 4 值匹配挑了不相干的 poc:5.2，把 review 发错了；实际自己在 poc:3.1 对应 poc:3.2（上轮 review 同一个 codex）。

0.7. **Phase 0 P0 检查清单**（顺序固定，不可跳）：
   (a) `echo $TMUX_PANE` 拿到 `%N` 形式 pane_id
   (b) `tmux list-panes -a -F '#{pane_id} #{session_name}:#{window_index}.#{pane_index} pid=#{pane_pid} pwd=#{pane_current_path}'` 全量列举
   (c) 用 pane_id grep 自己那行，确认 session:window + pwd 是预期的；如果 pwd 跟当前任务文件目录不一致 → 先 `cd` 回正确目录再继续，否则后续 4 值匹配会错
   (d) 在剩余 codex 行里挑同 session + 同 window + 同 pwd 完全匹配的；无匹配 → split 新建

## 通信

1. **tmux Enter 必须分开发**：`send-keys "text" Enter` 经常丢回车，改为 text + sleep 2 + Enter。**text 必须是一条完整消息**（最多一两句通知"看 /tmp/xx.md"），**不是把长内容拆 N 条逐行打字到 codex 输入框**——后者会污染 pane / 错乱排版 / 触发 codex 把每行当独立命令。长内容永远走 `/tmp/cc_to_codex_*.md`。
2. **建立双向通信**：一开始就把自己的 pane ID 告诉 Codex，避免单向轮询浪费时间
3. **用共享文件通信**：详细内容写 `/tmp/` 文件，tmux 只发通知摘要
4. **Codex 也会主动写文件**：`/tmp/codex_to_cc_*.md`，用户会提示你读

## 环境

5. **`.env` 含特殊字符不能 source**：用 `grep "^KEY=" .env | cut -d= -f2-` 提取
6. **`cp .env.xxx .env` 会覆盖运行时配置**：部署后注意检查关键配置是否被模板覆盖
7. **SSH 并发控制**：Codex 和 CC 同时 SSH 会打满连接。避免并行 SSH，遇到 `Connection reset` 等待恢复
8. **队列积压**：test 环境的 derive/image backlog 会阻塞新任务，部署前先清

## Review

9. **Codex 会独立 SSH 验证**：不要在报告里写假话
10. **"条件通过" 是有效结果**：记录未验证项，不强行标记全通过
11. **多轮 review 是正常的**：Kafka producer 改了 3 轮才通过，wave import 改了 2 轮
12. **Codex 能发现架构级问题**：如 kafka-go Writer.Topic/Message.Topic 互斥、UUID/int64 不兼容

## 执行

13. **Codex 权限弹窗会阻塞**：必须 full-auto，监控 capture-pane，发现 "Would you like" 就发 `y Enter`
14. **Codex context 会压缩**：长会话后重发关键信息。改进：使用 `/tmp/codex_context_anchor_${ANCHOR_ID}.md` 锚点文件（按 pane 命名，防止多 session 并行覆盖），每个 Phase 结束时更新，Codex context 压缩后只需 `cat` 锚点文件恢复
15. **migration 可能未执行**：部署代码后检查 DB schema 是否匹配
16. **Admin API 认证**：test 环境用 `X-Admin-Token` header，不是 JWT cookie

## Agent 管理

20. **并行 Agent 文件冲突**：多个 Agent 同时修改同一文件会冲突。规则：不同文件集可并行，同一文件必须串行或用 `isolation="worktree"` 隔离
21. **Agent 可能卡住**：长时间运行的 Agent 无响应时，检查 `/tmp/agent_progress_<task>.md` 进度文件判断状态。Agent prompt 中要求定期写进度
22. **Orchestrator 不是传话筒**：收到 Codex review 后，先分析意见合理性再决定修复方案。报告给 Codex 前，先自己跑一遍 acceptance criteria 自检。避免把明显不完整的实现提交 review

## 生产开关管理（P0 教训）

17. **测试/调试型开关修改生产配置后，必须立即恢复或获得用户明确确认才能保持开启。** 绝不能"临时开了就忘关"。包括但不限于：
    - `DERIVE_SKIP_TAGS`（LLM 成本）
    - `REFRESH_ENABLED`（refresh cycle 会产生大量派生任务）
    - `REFRESH_SCHEDULER_ENABLED`（扫描产生新 refresh）
    - 任何影响 LLM 调用、外部 API 调用、批量任务创建的开关
18. **临时修改 `.env` 不会被 git 追踪**：`sed -i` 改了 `.env` 但 `.env.refresh`/`.env.prod` 模板不变。下次 `cp .env.xxx .env` 会恢复模板值，但中间窗口的影响已经发生。
19. **教训**：2026-03-30 为验证 canary 临时开启 tags（`DERIVE_SKIP_TAGS=false`），忘记及时关闭，refresh scheduler 持续跑了 ~11 小时，触发了约 57,000 次 LLM tags 计算调用，造成不必要的成本。

## 类属性收敛（P1 教训）

23. **教训（2026-04-17, enrichment tags split）**：任务跑了 6 轮 Codex review cycle 才收敛，后 4 轮（v3→v6）blocker 都是"persisted 终态被 reconstruction 非终态覆盖"的**同构漏洞**，只是 `recovered.Status` 枚举值不同（ImageWaiting → Deriving）。根因：
    - Phase 1 spec 没声明 **Semantic Contract**（"Completed 是 canonical waiter 的专属信号"），下游所有依赖旧契约的 merge 规则都没列入影响面
    - Phase 5 review 粒度是 diff 不是 contract impact，Codex 逐点发现一次只指一处
    - Orchestrator 每轮只修当轮 blocker，没主动穷举 impact neighborhood
    - code-review-graph 在 Codex session 不可用，orchestrator 侧也没主动补齐
24. **规则**：
    - Phase 0 自检 graph 覆盖，必要时自动 `build_or_update_graph_tool`
    - 涉及状态机/合并规则/语义契约 → Phase 1 spec 强制声明 Semantic Contracts + orchestrator 跑 Impact Tracing 附 Impact List
    - Phase 5 驳回上限从 5 轮降到 3 轮；连续 2 轮 blocker 属于同一契约/同一 impact 簇 → 强制进入**穷举模式**（orchestrator 主动画 matrix 一次修完，不等 Codex 再点）
    - 这次 v5→v6 如果执行了穷举模式规则，能直接省掉 v6 这一轮
25. **Codex reviewer 的固有局限**：逐点而非逐类。LGTM 只意味着它这轮看的点都过了，不意味着同类模式都清扫干净。Orchestrator 必须主动承担"类属性修复"的决策。

## 进程内 wiring / 跨 cmd 共享 setter（P0 教训 2026-05-12）

26. **教训（RTM cmd/api wiring gap）**：PR #1124 在 cmd/data-center-control 调了 `handler.SetAdminEnrichCrawlerRESTFlags`，但 ordo-api 进程没调，导致 `adminEnrichCrawlerRESTFlags` 在 api 是 zero-value，admin enrich 的 RTM skip 分支是死代码。6 轮 Codex review 没抓到，因为 R5 加的 wiring guard test **只 grep 了 cmd/data-center-control/main.go**，没扩展到 cmd/api。生产 §5.B smoke 触发 admin enrich Twitch 才暴露。详见 `reports/tech/20260512_rtm_cmd_api_wiring_postmortem.md`。

27. **规则：wiring guard test 必须覆盖所有使用该 wiring 的 cmd**
    - 写 wiring guard 时先 grep 所有 import 该 handler/service 包的 cmd（`grep -rl "<pkg>"` ./cmd/）
    - 对每个找到的 cmd，写或扩展对应 `cmd/<X>/main_wiring_test.go`
    - guard 内容：(a) wiring setter 调用存在 (b) wiring 前的 ValidateConfig 调用存在 (c) 每个相关枚举/平台/feature 都 wire 了（防"wire 了 3/4 平台"）
    - **判断标准**：Go package-level 变量在每个 binary 内是独立实例。如果一个 `Set<X>(...)` setter 用于 wire 进程级状态，**所有 binary 都需要独立 call**——任何一个漏 call 就是 dead code

28. **规则：spec Impact List 必须包含"setter 跨 cmd 列表"**
    - Phase 1 spec §Contract Impact List 默认聚焦数据流（DB / schema / Kafka topic）。这是不够的。
    - 含 `Set<X>(...)` setter 的 wiring 变更，Impact List 必须显式加一行：
      > **Cross-cmd init wiring**: setter `<pkg>.Set<X>` 必须在以下 N 个 cmd 调用：[`cmd/a`, `cmd/b`, ...]
    - Phase 5 review 把"N 个 cmd 都 call 了"作为 hard checkpoint

29. **规则：生产 enable 后 5 分钟内必跑主动 smoke**
    - production gate 开关翻完（如 `*_ENABLED=true` flip + restart）后，**不要等自然流量**——5 分钟内主动跑 1 个该路径的 smoke 测试
    - 自然流量延迟可能 30 分钟到几小时，期间 wiring gap / 配置错误等 silent bug 难发现
    - smoke 失败 = 立即回滚或 hold，避免 silent fail 累积

## 外部依赖 / Pre-flight sample size / 回滚语义（P1 教训 2026-05-19）

30. **教训（YouTube RTM canary rollback）**：用 1 个 happy-path video_id (`27t8iUE_yE4`) 做 `/api/youtube/video_detail` pre-flight，enable 后 5min 内 backlog 上其他 video_id 出现 **76% HTTP 500 + envelope code=3001** "internal error"，触发 Codex §4 abort criteria。Rollback 5min 内落地。Root cause 在 crawler-server 那侧（reproducible deterministic），不是 ordo-backend bug。详见 `reports/tech/20260519_youtube_rtm_canary_rollback_postmortem.md`。

31. **规则：external dependency pre-flight 不能用单点样本**
    - 单 happy-path ID 只能证明"联通"，不能证明端点对生产真实分布稳定
    - 对涉及 fan-out / backlog 的开关（特别是 detail/expensive endpoint），pre-flight 必须 N ≥ 60 真实 sample
    - 样本必须来自**即将被 enable 的真实队列**（DB pending tasks），不要外部 hand-picked
    - 分层：失败 cohort / 成功 cohort / pending backlog / 多个 sub-type / 多个 owner
    - 同 ID 重试 3 次区分 deterministic vs 间歇
    - Concurrency=1 + canary 实际并发 两档都过

32. **规则：rollback 语义按 task 当前状态分类**
    - `status=0`（已 RTM-marked 但未 claim）→ flag=false 后 publishSingleTask 走 Kafka publish 分支
    - `status=2`（已 CAS claimed by RTM Worker）→ **不会自动 fall back Kafka**，任由 worker 完成 dispatch
    - `status=6`（retry exhausted terminal failed）→ 终态。Stale batch reconciler 不重发。需要业务侧处理
    - runbook / PR body 不要写"in-flight 全部 fall back to Kafka" — 这是错的，会误导

33. **规则：admin merge 跳 queued CI 的可接受边界**
    - 可接受前提：(1) 本地 targeted tests PASS (2) reviewer worktree 独立 verify PASS (3) 其他 CI 已 PASS (4) rollback owner 在场 + on-call ready
    - 但 queued CI green **不覆盖外部服务行为**；外部 endpoint 必须另有 live probe artifact 作为补充证据
    - 每次使用都要记录边界（commit message / PR comment），后续 retro

34. **规则：review scope 必须显式写外部依赖边界**
    - Codex review 能 cover ordo-backend diff / wiring / schema / guard tests
    - **不能从代码静态证明上游服务对真实样本稳定**
    - 涉及外部依赖的 PR，brief / spec 必须列 "上游依赖责任边界"
    - live probe artifact 作为 review input（不是替代）

35. **规则：HTTP 5xx envelope code observability gap**
    - 当前 `CrawlerRESTClient` 在非 200 分支 `CrawlerRESTError.Code` 是 0，envelope JSON 不解
    - 上游返回 `{"code":3001,"message":"internal error"}` 包含的 code 看不到，影响聚类排查
    - P2 hardening：5xx body best-effort envelope parse，仅用于日志/metric

36. **规则（hardening）：platform-level circuit breaker**
    - 当前 RTM Worker 在 enable 后秒级 claim 大量 backlog；如果上游不稳，5min 内可 claim → terminalize 大量 tasks
    - in-memory platform breaker：2min 窗口 failures ≥ 10 且 fail_rate ≥ 50% → open；cooldown 10min；不自动改 env
    - 不阻断当前 enable 流程，但是下次 enable 前置希望落地
    - 详见 postmortem Action Items P1/P2

## 通信闭环（P0 教训 2026-06-30）

37. **教训（PR #2038 review verdict 未回传）**：Codex 在 %8 pane 内完成 review 并给出 LGTM，但**没 `tmux send-keys` 回传到 implementer pane %7**。implementer 按"不轮询 Codex"纪律纯被动死等，直到**用户介入点破**才去 `capture-pane` 拉取，才发现 review 早已完成。回路没闭环 = 阻塞被隐藏，靠人肉补救。根因是三重结构缺陷叠加：
    - 回传是**单通道易失推送**（tmux send-keys），无 ACK、无持久落点。send-keys 丢一次，信号就永久丢失。
    - 完成信号没有 **source-of-truth 文件**，结论只存在于 orchestrator 自己的 pane 滚动缓冲里。
    - implementer 被"禁轮询"纪律约束 → **纯被动**，没有任何"超时兜底拉取"的触发条件，于是死等。

38. **规则：每个 phase 结论走"持久文件 + tmux 通知 + 收方 ACK"三段闭环，不是单向推**
    - **Orchestrator 侧**：spec-ready / review-verdict / fix-decision 等每个 phase 结论，**必须先写持久文件**（`/tmp/codex_to_cc_<task>.md` 或 `/tmp/codex_review_verdict_<task>.md`，文件是 source of truth），**再** `send-keys` 通知。review 完成不回传 = 该 phase **未完成**。
    - **Implementer 侧（兜底，不许纯被动死等）**：发出 self-report / 提问后，约定一个超时阈值（默认 ≤10min，与 skill「Long silence over 10 minutes」对齐）。**超时无回传 → 主动 `tmux capture-pane -t <codex_pane> -p | tail` + 读约定 verdict 文件**判断对方是否已出结论。这是"禁轮询"的合法例外：轮询=高频空转打扰；超时兜底拉取=一次性确认对方状态，必须做。
    - **闭环 ACK**：收方（无论 implementer 还是 orchestrator）拿到对方结论后，回一条简短 ACK（"已收到 verdict，进入 X"），形成"推→收→确认"三段，而不是"推完即完"。纯 ACK 是这条规则唯一允许的例外（平时跨 pane 回传要带"结合对方反馈的再判断"，见 CLAUDE.md 多 Agent 协作纪律）。
    - **判断标准**：任何"我在等对方"的状态持续超过阈值且没主动核实过对方 pane/文件 = 回路未闭环，是严重问题，不是"再等等"。

## 评审循环失控（教训 2026-09-20，邮箱已读同步 PR #3750）

39. **教训**：Codex 七轮 BLOCK。r1/r6 是真缺陷；r2/r3 半真；r4/r5 是冻结 DB 时钟 + 逻辑时钟领先微秒才能构造的平局，Codex 自己写"不称生产高频"，orchestrator 仍逐条派修。结果：会话表 8 列（3 列纯为并发加）、行锁事务、约 3 小时评审循环，需求本身 3 列可做。
    - 根因 1：spec 没写"快照 / 事件 / 手动动作冲突谁赢"，实现和评审各自发明机制（转变驱动 → 时间戳 → 版本 CAS → 逻辑时钟）。
    - 根因 2：把每条 BLOCK 当指令，没在同主题第 2 轮停下问"值得修吗、有没有更简单的不变量"。
    - 规则：见 SKILL.md「Review finding → ROI decision」——评审发现是决策输入不是工单；每条 BLOCK 先列 修/简化/接受为已知缺口 三项的时间成本效果，选综合最优；不可达的默认接受；要加锁/时钟/版本列先比简化；同主题第 2 次先补不变量。用户 09-20 原话：该讨论出 ROI 最高的方案，不一定最合理，但一定是时间、成本、效果综合最优。

