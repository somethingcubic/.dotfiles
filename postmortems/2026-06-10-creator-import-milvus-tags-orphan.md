# Postmortem: creator-import Milvus 缺人 95.8% —— enrichment tags 孤儿化

**日期**: 2026-06-10
**项目**: ordo_ai (/Users/qiansenmiao/Documents/Projects/ordo_ai_milvus)
**严重程度**: 高（单批次 95.8% 达人进不了向量搜索；且 dry-run 证明同根因每天静默丢 ~1.4k 达人，已持续未知时长）

## 时间线

- **11:19-12:02 BJT** 导入执行：`creator-import-20260610-e4eadd`，2593 个 YouTube 达人，GUI 显示全部 "submitted"
- **15:25** 用户报告：DB 导入成功但 Milvus miss 很多人
- **15:30-15:50 排查**：进度文件 → DC `ordo_creator_enrichment_jobs`（110 completed / 2483 failed）→ 失败分类（`derive job timed out or missing` 1573 + `video_info is None` 826 等）→ Core 对账（1806 在库，其中 1696 tags 空且 sync_hash NULL；787 不在库）→ derive job 指纹 `status=success + step_tags_status=pending` → 根因闭环
- **16:00 手动补救**：对 3290 个 derive 行置 `DirtyTags|DirtyCost`（bulk.ctrl），先 SELECT 确认行数再分批 upsert；10 分钟全收敛，Milvus 覆盖 110 → 1789；剩余 804 人为内容缺失（重爬范畴），0 失败
- **16:30-18:00 修复设计**：限速方案被数据证伪（导入已是 submit_rps=1 最低速档仍 61% 超时）；确立 reconciler 方向；Codex spec 对抗评审两轮 reject（采纳：条件 UPDATE 替代 upsert、WHERE 排除 running 行、keyset 分页 + 预算分离）；生产 dry-run 发现 **7 天窗口 14,004 孤儿行 / 9,979 达人——泄漏是常态非导入特有**
- **18:00-19:10 实施**：TDD（7 sqlmock 用例）→ CI idempotency-lint 误报按豁免机制标注 → 实现 review 抓出 per-instance 预算语义（双实例 affected=0 不耗预算 → prod 对各设 1000 保全局 ≈2000/10min）→ PR #1739 merge
- **19:18-19:20 部署** prod + refresh；首轮各补发 1000
- **19:30** 同事并发部署其他 PR 重启了进程——条件 UPDATE 幂等设计无损通过（意外的崩溃恢复实战验证）
- **22:00+** 收敛至稳态：每轮 2-32 行（实时新增孤儿），部署以来 embedding 链路 0 失败

## 根因分析

- **表面原因**：1573 个 enrichment 在「等 derive 成功」120 秒窗口（`enrichment_derive.go:28`）超时被标 failed，tags 派生请求从未发出 → `ordo_creators.tags` 空 → 向量同步按设计跳过空 tags（`dashvectorsync/data.go:651`）
- **根本原因**：tags 派生的触发被设计为**内存中同步等待链的最后一环**（等 derive → 等 image → 入队 tags，`enrichment_derive.go:60-80`）。等待者是进程内 goroutine，超时、失败、发版重启任何一种都使其消亡，而「放弃等待」被错误地等同于「放弃数据」——没有任何状态扫描型兜底负责收敛
- **系统性因素**：
  1. 项目已有 stale batch reconciler 的「主路径 + safety net」模式，但 tags 这条关键派生链没有套用
  2. 导入工具以「submitted」冒充成功（2593 行全显示 submitted，实际 95.8% 未走完），掩盖了问题暴露
  3. 无 tags 覆盖率类监控指标——每天 ~1.4k 达人静默丢失持续了未知时长才由一次大导入放大暴露
  4. DC 的 qwen LLM 调用不进任何成本表（`ordo_llm_cost` 已停写、`beacon_llm_*` 不覆盖 data-center）——修复的成本影响只能估算

## 教训

1. **同步等待超时只能管上报，不能管数据完整性。** 任何「fire-and-wait」链尾部的关键动作（入队、落库、触发下游）必须有独立的状态扫描型 reconciler 兜底，签名设计成自清幂等（做完即不再匹配）。等待者是内存 goroutine——超时、panic、发版都会让它消亡，把数据完整性押在它身上 = 必然丢数据。本次违反后果：单批 95.8% 丢失 + 常态每天 ~1.4k。加长超时不是修复（窗口越长发版丢的越多，"timed out **or missing**" 的 missing 半边）。
2. **error class 字符串 ≠ 可补救性，自动化补救判定用结构条件。** 事故数据：40 个 `video_info is None` 在库达人中 39 个可救——按错误消息白名单会漏；按「数据存在性 + 状态字段」（derive 行存在 + step_tags=pending + dirty 位未置）判定既准确又不随措辞腐烂。
3. **多实例 maintenance loop 的预算/幂等按「N 实例同时跑同一扫描序」推演。** 条件 UPDATE 的 affected=0 不耗预算 → RowsAffected 计数的预算是 per-instance 语义，N 实例合计 ≈ N×预算。代码正确 ≠ 容量披露正确；review 时把「双实例」当作显式攻击维度。
4. **复杂度估算要先量产线基数。** 我按事故规模（2.5k）锚定设计参数，dry-run 实测 7 天窗口 71,904 failed enrichment / 14,004 孤儿——差 27 倍。涉及扫描/回填的设计，先跑一次真实数据的只读 dry-run 再定参数。

## 行动项

- [x] PR #1739 TagsOrphanReconcile 上线（prod + refresh），存量 14k 已收敛
- [ ] PR-2：导入工具 completion-gating + 终态回查真实成功率（spec 已写，`reports/tech/20260610_tags_orphan_reconciler_spec.md`）
- [ ] P2（暂缓）：enrichment 流量分类拆分（导入标 bulk、不走同步等待），触发条件见 spec
- [ ] DC（derived-worker tags/视觉调用）接入 beacon LLM 成本统计——当前每天数千次调用在成本监控里隐身
- [ ] 排查 embedding 队列 4172 个历史 failed 行（与本次无关的旧账）
- [ ] 可选：大 lookback 手动跑一次 `RunTagsOrphanReconcileOnce` 收敛 >7 天历史孤儿（LLM 成本需单独决策）
- [ ] enrichment 表畸形 creator_id（`instagram:@[{'cellPosition'...`）上游清洗

## 全局更新建议（待用户确认，未自动应用）

1. **项目 CLAUDE.md「异步任务与批处理」节**加一条：「同步等待链尾部的关键动作（入队/落库/触发下游）必须有 reconciler 兜底，超时只管上报不管数据完整性」——与现有「非 scheduler 批次也必须接入统一收口」同性质，是它的推广形式
2. **auto memory（feedback）**：教训 3（per-instance 预算语义）和教训 4（设计参数先 dry-run 量基数）属于跨项目可复用的工程直觉，建议入全局记忆
3. 教训 1/2 偏项目语境，存档本文件即可，不必扩散
