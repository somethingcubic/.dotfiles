# Postmortem: `ordo_creator_embedding_queue` 清扫器跨索引死锁

**日期**: 2026-04-13
**项目**: ordo-backend (`/Users/qiansenmiao/Documents/Projects/ordo_ai_spec_debug`)
**严重程度**: 中（prod 反复死锁但服务未中断，高峰期 CPU load 飙至 9+）
**修复 PR**: OrdoAI/ordo_ai#782 `fix(dashvectorsync): eliminate embedding_queue sweeper cross-index deadlock`

## 时间线

- **2026-04-13 11:49:10** —— prod 抓到一次死锁（T1 prod sweeper, T2 refresh worker complete），InnoDB 回滚 T1，`SHOW ENGINE INNODB STATUS` 记录为 LATEST DETECTED DEADLOCK
- **11:47 左右** —— 用户问"目前有死锁吗？"，开始调查
- **11:49 → 14:28** —— 期间又发生了第二次死锁（14:28:09），T1 持有 lock struct 从 4 涨到 17，说明 stuck 行随 sweeper 周期累积、冲突面持续扩大
- **14:58:09 / 14:58:15** —— prod 和 refresh 各自的下一轮 sweeper 把 14:28 死锁留下的 38 行（8 + 30）从 processing 重置回 pending，系统自愈一轮
- **~14:30** —— 诊断完成，定位到 `ResetStuckEmbeddingJobs` vs `CompleteEmbeddingJob` 跨索引加锁顺序相反
- **~14:45** —— 写提案，Codex spec review 给出 4 个 blocker
- **~15:00** —— 按 review 意见改出 PR #782 初版
- **~15:15** —— Codex implementation review 给出 2 个 nit（表述过度 + 缺 regression test），全部采纳
- **~15:20** —— 部署到 test3 smoke test：注入假 stuck 行，验证 Fix 1 SQL 路径和 Fix 3 2-min 节流均按预期生效，0 deadlock
- **15:40** —— PR #782 squash merge 到 main (`38b4201c`)
- **15:46** —— 部署到 prod + refresh，两个 `ordo-sync-queue` / `refresh-sync-queue` 重启成功
- **15:46 → 16:02（16 分钟观察）** —— 0 新 deadlock，0 错误，sweeper 每 2 min 跑一次全部返回 0 stuck 行；prod load 从 9.06 → 0.25
- **16:04** —— 共享 RDS 的 LATEST DETECTED DEADLOCK 仍冻结在 14:28:09，修复生效

## 根因分析

### 表面原因

[已验证] `ResetStuckEmbeddingJobs` 的原 SQL 是一步走：

```sql
UPDATE ordo_creator_embedding_queue
SET status='pending', processing_version=NULL, updated_at=UTC_TIMESTAMP()
WHERE status='processing'
  AND updated_at < DATE_SUB(UTC_TIMESTAMP(), INTERVAL 30 MINUTE)
```

prod EXPLAIN 证实 MySQL 优化器选 `idx_status_created(status, created_at)`（leading column 匹配 `status`），扫二级索引 → 回表 PRIMARY。加锁顺序：**二级索引 → PRIMARY**。

与此同时 `CompleteEmbeddingJob` 经 `uk_creator_content(creator_id, content_type)` 定位，先锁 PRIMARY → 修改 `status` 列时维护所有含 status 的二级索引（`idx_status_created`、`idx_status_requested`、`idx_status_embedding_requested`）。加锁顺序：**PRIMARY → 二级索引**。

两个事务在同一物理行交汇，加锁顺序相反 —— 必然死锁。

### 根本原因

[推断] 写"看上去最自然"的 SQL 时，没有考虑：

1. **MySQL 优化器会基于代价模型选择索引**，并不保证和其他写路径一致的访问路径
2. **InnoDB 更新 clustered record 时，secondary index 锁的获取顺序由扫描方向决定**，而不是由开发者意图决定
3. **同一行上多个事务如果入口不同（uk_creator_content vs idx_status_created），加锁顺序天然相反**，不强制 pin 就注定出问题

更深一层的根因是**对 deadlock-critical SQL 的设计习惯缺失**：清扫器、reconciler、batch update 这类可能和正常路径在同一行上并发的 SQL，应该显式拧紧访问路径和加锁顺序，但代码库里没有这样的约定。

### 系统性因素

1. **没有单元测试锁定 SQL 形态**：`ResetStuckEmbeddingJobs` 只有集成测试间接覆盖，没有 sqlmock 测试断言 `FORCE INDEX (PRIMARY)` 和 `ORDER BY id ASC` 这种 contract。未来 refactor 删掉 hint 不会被 CI 发现
2. **双进程共用一张表但互不协调**：prod `ordo-sync-queue` 和 refresh `refresh-sync-queue` 都跑同一个 binary，都做 sweep 和 worker，都会触碰同一行，但 sweeper 不按 lane 过滤 → 冲突面被放大
3. **sweeper 频率没有和 staleness 阈值挂钩**：30 分钟的 staleness 窗口本来不需要每 10s 查一次。cost 本身是 "每轮 tick 都 sweep" 这个懒惰的默认值
4. **缺少死锁告警**：两次死锁（11:49、14:28）都是我主动查 `SHOW ENGINE INNODB STATUS` 才发现的，没有主动通知。生产上 deadlock 应该进监控面板
5. **Prod high load 没有归因**：部署前 prod load 9.06，事后对比发现就是死锁 churn 造成的 CPU 消耗。这个本来可以靠日常 CPU 告警提前发现

## 教训

### 教训 1：同一热点行上有多个写路径时，deadlock-critical UPDATE 必须显式 pin 访问路径 + 加锁顺序

**规则**：对于"会和其他写路径在同一行上并发"的 UPDATE（典型：sweeper、reconciler、batch reset、超时回收），必须两个都加：
- `FORCE INDEX (PRIMARY)` 或等价 hint，不让 cost-based optimizer 自由选择
- `ORDER BY id ASC`（或其他主键列）让加锁顺序成为显式契约

**适用场景**：sweeper / reconciler / stale reset / retry loop 这类回扫任务，目标表同时被 claim/complete/fail 等正常路径写入。

**违反后果**：优化器一旦走 secondary index，加锁顺序就和正常路径相反，**必然死锁**。不是偶发，是可复现的。

**反面教材**：原 `ResetStuckEmbeddingJobs` 以为 `WHERE status='processing'` 会走"某个合理的索引"，结果优化器选 `idx_status_created`，死锁在所难免。

### 教训 2：Sweeper 类任务用"两步走"，不要写一条大 UPDATE

**规则**：需要按复杂条件扫一批行然后更新时，拆成两步：
1. **Step 1**：普通 `SELECT id FROM ... WHERE <cond> LIMIT N`（**不要 ORDER BY**，除非索引支持，否则 filesort）—— 这是 MVCC 非锁定读，不会和别人死锁
2. **Go/Python 代码层**：`sort(ids)` 升序
3. **Step 2**：`UPDATE ... FORCE INDEX(PRIMARY) WHERE id IN (...) AND <原 cond 二次校验> ORDER BY id ASC` —— 强制走 PRIMARY，加锁顺序固定

**适用场景**：任何扫大表 + 按条件更新的场景（stale reset、批量标记、清理任务）。

**违反后果**：
- 单条 UPDATE 的访问路径被优化器控制，无法保证 PRIMARY-first
- 无法用 `LIMIT` 限制单批锁面（`UPDATE ... LIMIT` 和 `ORDER BY` 组合在含非覆盖索引时会走 temporary table 或 filesort）
- 两步之间 worker 可能已经处理了其中某些行，靠 Step 2 的 WHERE 二次校验能安全跳过

### 教训 3：Backstop 定时任务的频率要和它的 staleness 阈值挂钩，不要每 tick 都跑

**规则**：如果一个任务的语义是"每 N 分钟兜底检查一次"（比如 30 min stale reset），那么它的执行频率应该是 `N/k`（k 取 10-20 之间），而不是和主事件循环同频。

**适用场景**：stuck sweeper、timeout reaper、stale cleaner、lag monitor 等"兜底"类任务。

**违反后果**：
- 浪费 CPU 和锁预算
- 如果兜底逻辑本身有缺陷（比如本次的死锁），每 tick 跑会把缺陷放大 N 倍
- 给监控系统制造噪声

**本次现场**：refresh 每 10s 跑一次 sweeper → 2 min 跑 12 次 → 12 次机会撞死锁。改到每 2 min 跑 1 次后，机会降到 1/12，本质上和修复 SQL 是正交的改进。

## 行动项

- [x] PR #782 合入 main
- [x] 部署 prod + refresh
- [x] 16 分钟观察：0 新死锁，load 从 9.06 降至 0.25
- [ ] **24 小时后再查一次** `SHOW ENGINE INNODB STATUS`，确认 LATEST DETECTED DEADLOCK 仍停在 14:28:09
- [ ] **一周后**再确认死锁没有其他未预期模式
- [ ] [可选，未排期] 为 `ordo_creator_embedding_queue` 补 `(status, updated_at, id)` 索引 —— Codex 建议，属于效率优化不是正确性修复
- [ ] [可选，未排期] 让 sweeper 按 lane 过滤（原 Fix 2 方案），进一步降低双机冲突面
- [ ] [流程改进] 考虑给 prod `SHOW ENGINE INNODB STATUS` 的 LATEST DETECTED DEADLOCK 加主动监控/告警 —— 这次两次死锁都是我手动发现

## 证据索引

- Codex spec review：`/tmp/codex_to_cc_embedding_queue_review.md`
- Codex implementation review：`/tmp/codex_to_cc_embedding_queue_impl_review.md`
- Proposal（含 EXPLAIN 对比）：`/tmp/cc_to_codex_embedding_queue_deadlock_proposal.md`
- 完整 InnoDB status 快照：`/tmp/innodb_status.txt`（11:49 死锁）、`/tmp/innodb_status_v2.txt`（14:28 死锁）、`/tmp/innodb_status_v3.txt`（post-deploy）
- 修改文件：
  - `ordo-backend/data-center/model/embedding_queue.go`（`ResetStuckEmbeddingJobs` 重写 + 测试 `embedding_queue_test.go`）
  - `ordo-backend/internal/dashvectorsync/queue.go`（`stuckSweepInterval` + `shouldRunStuckSweep`）
  - `ordo-backend/internal/dashvectorsync/service.go`（Syncer 加 `lastStuckSweepAt`）
