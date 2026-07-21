# Skill / Command 路由

> 供 agent 在选择 skill / command 时参考。红线、硬性触发（think-unstuck / verify / pre-submit-review / pipeline-debug-protocol）与体量分档以 CLAUDE.md 为唯一源，本文件只管"何时调用哪个能力"的细分路由。

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

## 实现流程

- 按体量选编排：见 CLAUDE.md「工作模式 · 接单先估体量」（重型 → codex-driven-dev / workflow；中型 → worker agent + 交叉 review；轻型 → 自己做）
- 改完后压缩冗余 → `/simplify`

## 文档写作

- PRD → `prd-writer`（当前 skillOverrides 已停用，需先在 settings.json 启用）
- 技术方案（基于 PRD） → `tech-spec-writer`（同上，已停用）
- 发布说明 / changelog → `release-note-writer`（同上，已停用）
- 踩坑复盘（沉淀全局记忆） → `/postmortem`

## 常见组合工作流

- **新需求 / 大改动**：`/think-map`（陌生仓库时）→ `/think-refine`（需求模糊时）→ `/think-plan` → `codex-driven-dev` → 实现 → `/simplify` → `verify` → `pre-submit-review` → push → `cross-review`
- **方案选型**：`/think-research` → `/think-compare` → `/think-plan`
- **开放调研 → 决策**：`/think-survey` → `/think-research` → `/think-plan`
- **Bug 排查**：pipeline 类 → `pipeline-debug-protocol`；非 pipeline → `debugging-discipline` skill 分诊协议（先止血再 RCA）
- **大改动前评估**：`/think-quality` → 决定拆分粒度 → `/think-plan`
- **卡住**：连续失败 2 次 → 必须 `/think-unstuck`

## 跨 agent 兼容

- 子任务派发用通用描述，不绑定特定 subagent 名
- 工具引用用通用名（Read / Grep / Glob / WebSearch / Edit），不引用 droid 专属 `Task` 或 `/missions`
- 路径默认相对仓库根
- 并行子任务在不支持的平台降级为顺序执行
