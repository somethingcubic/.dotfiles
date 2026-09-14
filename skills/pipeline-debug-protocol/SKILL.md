---
name: pipeline-debug-protocol
description: >-
  涉及后端 pipeline 性能、延迟、积压、吞吐排查时必须先调用。提供事实优先协议：
  假设先给证伪测试、优先做对照组 diff、先查时间戳 writer、只看实现不看符号名。
  Triggers: slow, stuck, backlog, 积压, 慢, 卡住, 延迟, bottleneck, throughput,
  pipeline 吞吐. Skip only for trivial single-line fixes or non-pipeline issues.
---

# Pipeline Debug Protocol

**用途**：事故/性能排查前的**纪律 skill**。不提供具体排查步骤（那是 refresh-diagnose 等场景 skill 的职责），而是强制执行**事实优先**的调查方法论。

基于 2026-04-22 YT video_detail 积压事故的 10+ 轮错误推断教训沉淀。

## 触发条件

用户提及任何下列场景时**必须**先调用本 skill：

| 信号词 | 例子 |
|---|---|
| 积压 | "25 万 pending 堆着"、"消化不完"、"backlog" |
| 吞吐 | "吞吐只有 X 条/秒，理论应该高"、"为什么只发这么慢" |
| 延迟 | "从 A 到 B 要 X 秒，太慢了"、"latency 不正常" |
| 卡住 | "refresh 卡住"、"任务过不去"、"stuck" |
| 两边都闲但慢 | "dispatcher 闲、爬虫闲，但消息就是不流动" |
| 反复事故 | "上次修完又来了"、"同一个问题第 N 次出现" |

## 硬性协议（全部必守）

### 1. 先读事实地图

开始任何 grep / SSH / SQL 之前：

```
cat docs/pipeline/data_pipeline_fact_map.md
```

核对：
- 涉及的组件跑在哪台机器、哪个 binary、哪个 env 开关
- 相关时间戳字段的 writer（**关键**：received_at 是 ingester 写的还是 worker 写的？这类问题只能从地图答）
- 同代码路径是否有多个流量类型（rt / bulk / enrich 等）

地图过期（`git log` 显示最近架构改动没同步）→ 先更新地图再排查。

### 2. 每个假说给证伪测试

**禁止"软假设"**：不要写"A 可能是瓶颈"。要写：

> 假说：A 是瓶颈  
> 证伪测试：如果 A 是瓶颈，应该观察到 X。  
> 验证：实际观察到 / 没观察到 X → 接受 / 否定假说

**例子**（来自 2026-04-22 事故）：

- 坏：*"dispatcher 串行 for-loop 可能是瓶颈"*
- 好：*"假说：dispatcher 串行是瓶颈。证伪测试：如果是通用代码问题，bulk.heavy 路径（同代码）应该也吞吐很慢。验证：查 bulk.heavy 吞吐数据——如果和 rt.heavy 相当就成立，如果 bulk.heavy 正常就否定"*

### 3. 对照组 diff 先于深挖

**同代码路径、不同表现 = 天然 A/B 对照**。优先对照再往下挖。

常见对照对：
- rt.heavy vs bulk.heavy（Ordo pipeline）
- refresh_* vs high_*
- prod vs refresh server（两台机器同代码）
- 正常 batch vs 积压 batch（同一时间）

如果对照组表现差异 = 能缩小排查面 10-100 倍。

### 4. 时间戳/状态字段断言**先 grep 所有 writer**

禁止凭函数名推断字段写入时机。强制流程：

```bash
# 1. grep 所有 UPDATE
grep -rn "UPDATE <table>" ordo-backend/ --include="*.go"

# 2. grep 所有 SET <field>
grep -rn "SET <field>\|<field> = " ordo-backend/ --include="*.go"

# 3. grep 所有 INSERT INTO <table> 包含 <field>
grep -rn "INSERT INTO <table>" ordo-backend/ --include="*.go"
```

逐个 Read 上下文确认：
- 该 writer 是主路径还是 fallback？
- 触发条件是什么？
- 在什么事务里？
- 是否有 CAS？
- **该字段会被哪些"清理路径"污染？**（retention 删除、cleanup reset、CompleteJob 重置 attempts、清理操作覆盖等）

**教训**：2026-04-22 事故里把 `received_at` 归到 result-worker，实际是 result-ingester 事务写（在 `enqueueSuccessResult` 里和 `result_jobs` INSERT 同事务）。

### 4.5. 事故 N 天后排查 — DB 字段是被污染的，OSS / artifact 是干净的

**强制规则**：事故已过 1+ 天后排查时，**必须**先列出每个相关 DB 字段的 writer + 清理路径（retention 时长、reset 逻辑、cleanup 调用）。如果字段会被路径污染，**禁止**直接用它反推事故时状态。

**优先级**（高 → 低）：
1. **OSS / 对象存储 / S3** — 通常无 retention（或保留期长），LastModified / object metadata 不会被覆盖
2. **不可变事件流** — Kafka offset / log append-only / DB binlog
3. **业务表的不可变字段** — `created_at`、`task_id`、固定外键
4. **状态字段** — `status`、`updated_at`、`step_*_attempts`、`dirty_flags` ← **会被污染**

**典型清理路径示例**（Ordo AI）：
- `SYNC_TASK_RETENTION_DAYS=3`：terminal sync_tasks 3 天后被删
- `SYNC_BATCH_RETENTION_DAYS=30`：但实际 prod 观察过 batch 表只剩 1 天
- `CompleteJob` 在 derive_job success 时 reset 所有 `step_*_attempts=0`
- `ClearExpiredLocks` 重置 `status='running'→'pending'`
- 手动 SQL 清理（事故响应中也算污染源）

**教训**：2026-04-27 derive zombie 事故，3 轮错误根因都基于污染字段（task retention 删了 / CompleteJob reset 了 / batch retention 只剩 1 天）。直到切到 OSS posts.json.gz 的 UpdatedAt（per-post 写入特征 vs UpsertPosts 批量写入特征）才拿到决定性证据，区分 D 路径（数据已写但没解锁）vs B 路径（数据没写）。

**反模式**（红线，立刻止步）：
- 看到 SQL 数字就解释（"8849/8899 没 task ⇒ 事故时没建 task"）— 没问"这数字会被什么路径污染"
- 用 `attempts` 字段反推事故时尝试次数（被 CompleteJob reset 污染）
- 用 retention 之后的 batch 表反推事故时 batch status

### 5. 看**实现**不看符号名

**禁止**依赖以下信息下结论：
- 函数名（`BatchWriteXxx` 名字含 "batch" 不代表实现是 batch）
- 注释头（可能过期）
- 变量名
- `.conf` 文件里的 `autostart=true`（可能服务器上被手工覆盖）

**必须**：打开源码读那几行实际代码。

**教训**：2026-04-22 事故里把 `BatchWritePostsFromSnapshots` 当成 batch API，但函数注释自己就写 "Sequential execution" —— for loop 逐条调 `updatePostDetail`。

### 6. 每个断言带 `file:line` 锚点

说 "X 写 Y 字段" 没锚点 = 未验证。说 "X 在 `a.go:123` 写 Y 字段" 才算事实。

事实地图 `docs/pipeline/data_pipeline_fact_map.md` 本身就是这个规则的产物——所有 writer 都有锚点。

### 7. 禁止 pattern

遇到以下行为**立刻止步**：

| 坏 pattern | 应当做 |
|---|---|
| 看到一个数字就铺理论（"3.7 条/秒 = XX 瓶颈"）| 先问"这个数字**实际测的是什么**"再解释：单位 byte/bit、wall/CPU、cumulative/delta、平均/最大值——单位错一位整套推论作废（5 MB/s vs 5 Mbps 差 8 倍） |
| 被用户反问就跳新假说 | 稳住事实锚点追问"为什么原假说不成立"而不是换一套 |
| 跨组件推断因果不读代码 | 至少读入口代码 + 关键 writer 再下结论 |
| 用函数名/注释字面意思下结论 | 读实现 |
| 基于 handoff / 他人总结直接推进 | 独立 verify 关键事实再用 |

### 8. 反问压力下稳住事实锚点

**用户反问不是驳回你的结论，是信号：你**的假说存在漏洞，但**不意味着答案就是你下一个假说**。

处理方式：
1. 承认反问的观察（承认新事实）
2. 判断：原假说是**不完整**还是**完全错**？
3. 不完整 → 补充；完全错 → 才换新假说
4. 每次切换要解释"原假说在什么前提下成立，为什么这些前提不成立"

**反例**（2026-04-22 事故连续发生）：
- 用户："Kafka 没积压啊" → 我立刻抛新假说"那是 dispatcher 串行"
- 用户："refresh 量比 rt 大为啥不积压" → 我立刻抛"两个 dispatcher 不同"
- 用户："还是没根因" → 我又抛 result-worker 串行
- **每次都没停下来验证原假说是否真的完全错了**，结果根因在 5 轮假说后才触到

## 成功标志

排查完成时，结论满足：

- [ ] 每个声明带 `file:line` 或 SQL 结果锚点
- [ ] 关键假说都过了证伪测试
- [ ] 对照组数据已查（如适用）
- [ ] 事实地图里有的信息优先用地图，没有的才现场查
- [ ] 结论经得住**独立 reviewer 用代码反查**（等同于能通过 Codex review）

## 和其他 skill 的关系

- `refresh-diagnose`：场景 skill。Phase 0 会引用本 protocol
- `codex-driven-dev`：排查结论要进 PR / spec 前，用这个流程让 Codex 独立验证
- `superpowers:systematic-debugging`：更通用的 debug 方法论；本 skill 是它在 Ordo AI pipeline 场景的特化版

## 教训引用

事故复盘（2026-04-22 YT video_detail 积压）列出 10 次跳跃式假说 + 5 类错误模式（看名字不看实现 / 单点证据跳结论 / 被反问带着走 / 缺证伪测试 / 不做对照组）。第三处事实错位：提议降 `DISPATCHER_PENDING_TIMEOUT_MIN` 会触发 `ExpireBatchTasks` 批量误杀活跃任务——改配置前先 grep 该配置的全部消费点。详见 `~/.claude/postmortems/2026-04-22-yt-video-detail-backlog.md`。
