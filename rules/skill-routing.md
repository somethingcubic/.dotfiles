# Skill / Command 路由

> 供 agent 在选择 skill / command 时参考。红线、硬性触发（think-unstuck / verify / pre-submit-review / pipeline-debug-protocol）与体量分档以 CLAUDE.md 为唯一源，本文件只管"何时调用哪个能力"的细分路由。

## 思考类（think-*，何时用哪个）

| 场景 | 调用 |
|------|------|
| 实现前技术选型 / 方案可行性 / 开放调研 | `/think-research` |
| 连续失败 / 卡住 / 漂移 | `/think-unstuck` |

## 实现流程

- 要不要开子 agent、开哪一类：见 CLAUDE.md「要不要开子 agent」（默认主会话自己做；体量大或涉及并发安全 → codex-driven-dev）
- 改完后压缩冗余 → `/simplify`

## 文档写作

- PRD → `prd-writer`（当前 skillOverrides 已停用，需先在 settings.json 启用）
- 技术方案（基于 PRD） → `tech-spec-writer`（同上，已停用）
- 发布说明 / changelog → `release-note-writer`（同上，已停用）
- 踩坑复盘（沉淀全局记忆） → `/postmortem`

## 个人 TODO 工作台（跨项目，与项目内 TASK.md 无关）

- 用户说"记个 todo / 看 todo / todo 整理" → CC 侧用 `/todo` skill；无 skill 的 agent（如 Codex）直接读写 `~/todos/`：`inbox.md` 只追加速记（`- [ ] MM-DD HH:MM 内容`），`TODO.md` 是看板，整理规则见 `~/.claude/skills/todo/SKILL.md`

## 常见组合工作流

- **新需求 / 大改动**：主会话实现或 `codex-driven-dev` → `/simplify` → `verify` → `pre-submit-review` → push
- **方案选型 / 开放调研**：`/think-research`
- **Bug 排查**：pipeline 类 → `pipeline-debug-protocol`；非 pipeline → `debugging-discipline` skill 分诊协议（先止血再 RCA）
- **卡住**：连续失败 2 次 → 必须 `/think-unstuck`

## 跨 agent 兼容

- 子任务派发用通用描述，不绑定特定 subagent 名
- 工具引用用通用名（Read / Grep / Glob / WebSearch / Edit），不引用 droid 专属 `Task` 或 `/missions`
- 路径默认相对仓库根
- 并行子任务在不支持的平台降级为顺序执行
