# Postmortem: YouTube Refresh 5 分钟内 ~2000 task FAILED

**日期**: 2026-04-27
**项目**: Ordo AI 后端 — `/Users/qiansenmiao/Documents/Projects/ordo_ai_main`
**严重程度**: 中（事故已止血，无数据丢失，但若不处理会持续放大）

## 时间线

### 事故发现（14:20-14:27）
- 用户报告：refresh 监控显示 YouTube 5 分钟内 2000+ task 失败
- 调用 `refresh-diagnose` + `pipeline-debug-protocol` 协议排查
- 关键证据：
  - 5 分钟 YT refresh FAILED ~361 个，其他平台 ≤ 2 个（YT 占 98.9%）
  - `Failed to parse user data: cannot unmarshal number into Go value of type kafka.UserData` ~1500 次
  - 一个失败 task 的 OSS snapshot **27 字节**，gunzip 解压后 = `404`（4 字节字符串）
- 根因定位（`consumer.go:793` ParseUserData → `result_ingest_service.go:156` 直接 marshal）：爬虫返回 status=SUCCESS + data.json=404 数字 → ingester 不校验直接落 OSS → result-worker 反序列化失败

### 用户决策（14:30）
- 用户截图说明爬虫端会统一返回格式（按 `~/Downloads/kafka-task-protocol.md`），让我做兼容
- 我**第一次行动过早**：直接改了 ParseUserData 兼容数字 raw，被用户打断"先别改，还不知道那边统一之后的格式"
- 回退改动，等用户给出协议文档

### 协议出来（14:40）
- 用户提供完整 4 形态协议：成功 / NotFound / NotFound+message / 参数错误
- 用户说"按这个 md 来收敛 publish 和 consume 的解析"
- 任务确认为重型契约变更，启动 codex-driven-dev

### 流程（14:40 - 17:25）
- **Phase 0/1**：Codex 写 spec v2（reject 1 轮 → 收敛）
- **Phase 2**：Team Agent 在 worktree 实施，~470 行净增 + 4 新文件
- **Phase 5 review 三轮**：
  - Round 1 reject：3 finding（分类边界 / 状态机缺 received_at / NormalizePlatform）
  - Round 2 reject：1 P1（markUserTerminalTx 漏 successResultAlreadyAcceptedTx）→ **触发类属性收敛**
  - Round 3 LGTM（穷举 matrix 9 格 + 5 sub-test）
- **Phase 5.5 adversarial 二轮**：
  - Round 1 reject：2 P0（Twitter fallback before accepted check / 旧 ingester null snapshot 击穿新 worker）
  - Round 2 LGTM
- **Phase 6 部署**：PR #987 squash → refresh 6 服务 → prod 14 服务

### 验证（17:35）
- Refresh 重启后 3min YT FAILED **0**（事故前每分钟 ~250-500）
- 新分类 aggregator 正常输出（YT video_detail / TT user / Twitch video 的 not_found 都是 `transitional=false` 合法终态）

## 根因分析

### 表面原因
爬虫在 not_found 路径下错误地返回 `data.json=404`（数字 raw JSON），而 `consumer.go:793 ParseUserData` 直接 `json.Unmarshal` 到 UserData struct，数字无法解析。

### 根本原因
1. **爬虫端协议不规范**：HTTP 状态码 404 被泄漏到业务数据层，违反 SUCCESS 必须返回对象的契约（最初的 SUCCESS+空对象 = banned 语义被破坏）
2. **下游 ingester 不校验 envelope 形态**：`result_ingest_service.go:156` 直接 `json.Marshal(result.Data.JSON)`，把任何形态都接受存到 OSS
3. **Parser 层不防御非对象 payload**：5 个 Parser（user/video/video_response/video_detail/reels）都假设 `data.json` 是对象形态，没有 envelope 分类层

### 系统性因素
1. **Kafka 消息 envelope 没有显式分类函数**：4 形态（Success/NotFound/InvalidParam/LegacyFailed）的判定散落在调用点，靠"unmarshal 后字段全空 + isEmptyUserResponse"间接识别。一旦爬虫发协议定义之外的形态（如数字），间接识别失效。
2. **状态机一致性靠 helper 复制粘贴维护**：`FinalizeFailedTask` 内已有 received_at + accepted-success 保护机制，但写 `markUserTerminalTx` 时只复制了部分（received_at），漏了 accepted-success → 同结构 bug 触发类属性收敛模式
3. **部署窗口契约：新旧 ingester/worker 共存时旧版本会篡改 snapshot**：旧 ingester 不认识 `data.error`，写 `null` snapshot 给新 worker，新 worker 看到的是 `json.RawMessage("null")`（不是 Go nil）→ classifier 失效。这是部署"中间态"风险，常规 review 看不出，必须 adversarial 才能找到

## 教训

### 教训 1：Parse 失败排查时，OSS snapshot 字节数是第一行证据
**规则**：当看到大量 "Failed to parse XYZ data" 错误时，**第一步先 ls -la 看 OSS snapshot 字节数**，远低于正常值（如 27B vs 几百B）= envelope 形态破坏，**直接跳到协议层排查**，不要先深入 parser 代码。

**适用场景**：result-worker / parser 错误激增、跨平台/单平台占比异常的事故排查。

**违反后果**：本次事故中我先深入 ParseUserData 实现 + 各种语义猜测才查到 snapshot 内容，多花 5-10 分钟。如果先看大小，能在 2 分钟内锁定根因。

### 教训 2：写"终态状态机 helper"必须 grep 同名 helper 的现有保护层逐项核对
**规则**：当为了走特殊路径而新建 `markXxxTerminalTx` / `finalizeXxxTask` 这类终态写入 helper 时，**第一件事是 grep 现有 finalizeXxxTx 实现**，把它的保护层逐条列成清单（事务 ctx detach / SELECT FOR UPDATE / accepted-success 检查 / received_at 推进 / batch counter / side-effect skip 条件等）→ 新 helper 必须**显式覆盖每一条**或显式注释为什么不需要。

**适用场景**：Ordo 风格的状态机一致性代码（task / batch / refresh DAG / result_job），任何"我自己写一个简化版" helper 的场景。

**违反后果**：本次事故的 Round 1 + Round 2 都因这个原因 reject。`markUserTerminalTx` 本质就是 `FinalizeFailedTask` 的简化版（去掉 emptyData 字符串识别），但漏了它的 accepted-success FOR UPDATE 保护 + received_at 推进，导致 user×NotFound 这一格的状态机契约和其他 24 格不一致。

### 教训 3：高风险 PR（并发/契约）必须走 Phase 5.5 adversarial，常规 review 看不出"中间态"问题
**规则**：变更涉及"并发竞态 + 跨服务通信契约"时，Codex Phase 5 LGTM 后**必须**追加一轮 adversarial review，焦点是：
- 双事务可见性（INSERT 未提交 vs SELECT FOR UPDATE）
- 新 helper 调用旧 helper 的 race window（如 fallback 在 accepted check 之前）
- 滚动部署期间新旧版本共存时数据流形态变化（如 RawMessage("null") 击穿新 nil 检查）
- 回滚不可逆点（数据库 schema OK 但语义不可逆）

**适用场景**：data-center / Kafka pipeline / 状态机 / 跨服务消息契约变更。

**违反后果**：本次 Phase 5.5 找出 2 个 P0（Twitter fallback before accepted、旧 ingester null snapshot），都是常规 review 不会发现的"中间态"问题。如果跳过 Phase 5.5 直接上线，至少会持续触发 Twitter fallback 误覆盖 accepted success（影响所有 refresh+twitter+user+retry_count=0+channel_id 非空且 success backlog 窗口内的 task）。

### 教训 4（工具）：worktree 隔离开发时 gopls diagnostic 是噪声，以 `go build` 实测为准
**规则**：在 `.claude/worktrees/<name>/` 里改代码时，gopls 反复报 "use of internal package not allowed" / "undefined: TaskService" / "use any instead of interface{}" 等，这些是 **gopls workspace 没把 worktree 包含进来**导致的假阳性。**忽略它们**，以 `cd <worktree>/ordo-backend && go build ./...` 的实际编译为准。

**适用场景**：用 codex-driven-dev / Team Agent worktree 隔离做 PR 开发。

**违反后果**：被 diagnostic 噪声误导去"修"不存在的问题会浪费时间。本次事故修复中我至少 3 次看到这种噪声，每次都用 `go build` 验证了真实状态。

## 行动项

- [ ] **(已完成)** 部署 PR #987 到 refresh + prod，事故止血
- [ ] **(已完成)** 写移除计划文档 `reports/tech/20260427_kafka_consumer_primitive_payload_removal_plan.md`
- [ ] 2026-05-04：检查 transitional=true raw_shape=number 命中量化
- [ ] 2026-05-11：评估是否可以移除 primitive payload 兼容路径
- [ ] 2026-05-18：若 7 天 0 命中 → 提 PR 删除 transitional NotFound + 测试
- [ ] **(待办)** 块 B（publish 端 TaskMessage 收敛）+ 块 C（dead queue 字段对齐）作为 followup PR
- [ ] **(待办)** 移除计划要求 durable counter（Phase 5.5 §6 caveat）：当前聚合 WARN 日志最后一批 bucket 可能不 flush，无法机器证明"7 天 0 命中"
