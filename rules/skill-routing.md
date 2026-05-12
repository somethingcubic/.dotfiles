# Skill / Command 路由

> 供 agent 在选择 skill / command 时参考。本文件不重复 CLAUDE.md 的红线和核心原则，只解决"何时调用哪个能力"。

## 硬性触发规则（高于偏好）

- 连续失败 2 次 / 跳跃式假说 / agent 路径漂移 → 必须 `/think-unstuck` 进入结构化排查（不允许"再试一次"）
- 后端 pipeline 积压 / 延迟 / 性能 / 吞吐 → 必须 `pipeline-debug-protocol`（CLAUDE.md 事故排查纪律已展开细则）
- 复杂多步骤实现（多文件 / >150 行 / 红旗变更）→ 必须先 `spec-driven-dev` / `codex-driven-dev` 写 spec，不允许直接动手
- PR 提交前 → `cross-review`（双 Agent 交叉评审）+ 内置 `/review` / `/security-review`

## 思考类（think-*，何时用哪个）

| 场景 | 调用 |
|------|------|
| 实现前技术选型 / 方案可行性 | `/think-research` |
| 开放性主题资料综述（不强制决策） | `/think-survey` |
| 多个方案 / 工具 / 路径取舍 | `/think-compare` |
| 需求不清 / 要写 spec / 阶段计划 | `/think-plan` |
| 接手陌生仓库做代码地图 | `/think-map` |
| 单次任务影响面 + 文件清单 + 风险 | `/think-context-map` |
| 复杂改动前评估结构可修改性 | `/think-quality` |
| 设计或梳理架构（产出可逐层阅读） | `/think-architecture` |
| 需求模糊 / 边界不清 / 多种解释 | `/think-refine` |
| 怀疑上下文不足 → 先列信息需求 | `/think-ask-context` |
| 连续失败 / 卡住 / 漂移 | `/think-unstuck` |

## 实现流程（按改动体量）

| 改动量 | 路径 |
|--------|------|
| 重型（多文件 / >150 行 / 并发 / 安全 / 数据一致性） | `codex-driven-dev` 编排 Codex 写 spec + review + Team Agent 实现 |
| 中型（单文件 / <150 行） | Worker Agent 实现，Codex 交叉 review |
| 轻型（<20 行 / 机械操作 / 常量调整） | 自己做，跳过 spec |
| 改完后压缩冗余 | `/simplify` |

详细见 CLAUDE.md "工作模式" + "验证开销要匹配改动体量"。

## 文档写作

- PRD → `prd-writer`
- 技术方案（基于 PRD） → `tech-spec-writer`
- 发布说明 / changelog → `release-note-writer`
- 踩坑复盘（沉淀全局记忆） → `/postmortem`

## 思想方法（qiushi-skill:*，复杂任务时考虑）

- 不知从何下手 / 优先级冲突 / 多个矛盾 → `qiushi-skill:contradiction-analysis`
- 多目标动态平衡（优化 A 伤害 B） → `qiushi-skill:overall-planning`
- 多任务争夺资源、必须聚焦 → `qiushi-skill:concentrate-forces`
- 长期复杂任务分阶段 → `qiushi-skill:protracted-strategy`
- 阶段验收 / 反复出错纠偏 → `qiushi-skill:criticism-self-criticism`
- 信息不足先调研 → `qiushi-skill:investigation-first`
- 从零起步找根据地 → `qiushi-skill:spark-prairie-fire`
- 收集多方反馈再验证 → `qiushi-skill:mass-line`
- 假设需要实践验证 → `qiushi-skill:practice-cognition`
- 选不出方法 → `qiushi-skill:workflows`（决策树）

## 常见组合工作流

- **新需求 / 大改动**：`/think-map`（陌生仓库时）→ `/think-refine`（需求模糊时）→ `/think-plan` → `codex-driven-dev` → 实现 → `/simplify` → 验证
- **方案选型**：`/think-research` → `/think-compare` → `/think-plan`
- **开放调研 → 决策**：`/think-survey` → `/think-research` → `/think-plan`
- **Bug 排查**：pipeline 类 → `pipeline-debug-protocol`；非 pipeline → 观察 → 假设 → 加可观测性 → 修复 → 验证
- **大改动前评估**：`/think-quality` → 决定拆分粒度 → `/think-plan`
- **卡住**：连续失败 2 次 → 必须 `/think-unstuck`

## 跨 agent 兼容

- 子任务派发用通用描述，不绑定特定 subagent 名
- 工具引用用通用名（Read / Grep / Glob / WebSearch / Edit），不引用 droid 专属 `Task` 或 `/missions`
- 路径默认相对仓库根
- 并行子任务在不支持的平台降级为顺序执行
