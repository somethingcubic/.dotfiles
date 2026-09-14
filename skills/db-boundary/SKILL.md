---
name: db-boundary
description: "涉及多 RDS / 多逻辑库 / DB handle 路由 / migration cutover / RDS isolation / read replica split 的 spec、实现或 PR review 时必须先读。包含 Writer Matrix、mixed-domain dual-handle、reject-mode sqlmock test、rehearsal traffic matrix 的硬性红线。"
---

# DB Boundary Discipline

> 适用任何涉及多 RDS / 多 logical database / handle 路由的项目（如 RDS isolation, multi-tenant sharding, read replica split）。源自 2026-05-24 ordo RDS isolation cutover 事故。

## 核心原则

**DB boundary 是 table-family ownership，不是 cmd/service/variable 名字。**

每张 SQL 表归属一个 domain。每个写入该表的 SQL（无论上下文、调用栈、变量名）必须用该 domain 对应的 DB handle。Service 名叫 "DataCenterFoo" 不代表它写的所有表都属 DataCenter domain。

## 红线（migration / isolation 场景零容忍）

### 1. Writer Matrix 是 spec 第一交付物（不是后补 audit）

任何 DB boundary split（CoreDB/RuntimeDB / Master/Replica / Tenant shard），**必须先**产出 writer matrix 文档：

```
| Table | Domain | Writer (cmd/service:file:line) | Handle Used | Expected | Status |
```

- 行覆盖：所有 INSERT/UPDATE/DELETE/UPSERT/REPLACE 写入点（grep 全部）
- 列必须有 file:line 锚点（dead anchor 算未验证）
- 必须列出每个 supervisor program 上跑的所有 writer
- 标 prod-only program vs 测试环境覆盖

**禁止跳过**这步直接动代码——历史教训：没 writer matrix 的 routing PR 90% 漏 cross-handle case。

### 2. Mixed-domain service 必须 dual-handle + reject-mode test

任何 service 同时写两个 domain 的 table（如同时写 `ordo_creators` 和 `ordo_creator_refreshes`）：

**禁止**：
```go
type FooService struct { db *sql.DB }  // 单 handle 混用 = 红线
func NewFooService(db *sql.DB) *FooService  // review hard gate 直接 reject
```

**必须**：
```go
type FooService struct {
    coreDB    *sql.DB  // for ordo_creators / owner fields
    runtimeDB *sql.DB  // for refresh/sync/derive runtime tables
}
```

**或**：refactor service 只写一个 domain，跨域通过 event/outbox。

### 3. Reject-mode sqlmock test

mixed-domain service 必有 two-handle test，**显式拒绝**错向写入：

```go
func TestFooService_HandleRouting(t *testing.T) {
    coreDB, coreMock := sqlmock.New()
    runtimeDB, runtimeMock := sqlmock.New()

    // 正向期望
    coreMock.ExpectExec("UPDATE `ordo_creators`").WillReturnResult(...)
    runtimeMock.ExpectExec("INSERT INTO `ordo_creator_embedding_queue`").WillReturnResult(...)

    // 反向 reject — 如果 SQL 走错 handle, mock unmet → test FAIL
    // 不需要显式 reject，ExpectationsWereMet() 严格匹配 = 反向自动拒绝
    
    svc := NewFooService(coreDB, runtimeDB)
    svc.DoWork(...)
    
    require.NoError(t, coreMock.ExpectationsWereMet())
    require.NoError(t, runtimeMock.ExpectationsWereMet())
}
```

PR 评审 hard gate：mixed-domain service 无此类 test → reject。

### 4. Rehearsal traffic matrix（不是单 platform sample）

Migration cutover rehearsal Phase F **必须**覆盖每 writer class：

- 每个支持的 platform 至少 1 个 admission traffic
- 每个 standalone batch writer 至少 1 个 invocation（如 twitch-vod-backfill / 类似 cron）
- 每个 DAG step 至少 1 个 cycle 到 terminal

**显式**列出 test 环境不跑的 prod-only writer，标记 "rehearsal 不覆盖，依赖 architectural review 保障"。

简化 rehearsal（如"不启 traffic 直接 sample"）= rehearsal 失去 commit gate 验证意义。

## PR review checklist 应用

任何 PR 涉及多 DB handle / migration routing 的，review 前 mechanical 检查：

- [ ] Writer matrix 在 spec 里且 file:line 锚点全 verify？
- [ ] 所有 mixed-domain service constructor 接收 ≥2 handle？
- [ ] 内部 SQL grep 每条都 trace 到正确 handle？
- [ ] Reject-mode sqlmock test 覆盖所有 mixed-domain service？
- [ ] Rehearsal traffic matrix 覆盖每 writer class？

任一未满足 = block merge。

## 教训锚点

**2026-05-24 ordo RDS isolation cutover incident**：
- PR-1 Core/Runtime split 只 swap service 注入的 db handle，未确保 service 内部 SQL 跟 handle domain 一致
- 5 个 service（derived-worker tags/metrics/cost / image-transfer-worker / VideoDetailService / refresh-temporal-worker / twitch-vod-backfill / twitch-sullygnome-sync）在 dc_primary 下 cross-handle 写错地方
- Code review (跨文件 grep miss) / 单元 test (单 handle mock 不区分 domain) / Phase 0.6 rehearsal (Phase F 无 traffic 没 exercise DAG) **三道防线全部漏过**
- Cutover Step 8 第一次真 traffic 才暴露：Core embedding_queue 漏 11 行 + 957 UPSERT / image_jobs 2428 失败 (Error 1146 table doesn't exist)
- S5-light rollback 干净退出，6 行 DC orphan，业务零损失
- Lesson reframe：DB boundary 不是 service 名字、不是 cmd 名字、不是变量名 — 是 **table-family ownership**
