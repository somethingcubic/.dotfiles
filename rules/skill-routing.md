# Skill / Command 路由

> 只写 AGENTS.md「Skill 路由」一节以外的细分路由。红线和硬性触发（think-unstuck、verify、pre-submit-review、pipeline-debug-protocol）以 AGENTS.md 为准。

- 实现前技术选型、方案可行性、开放调研 → `/think-research`；连续失败 2 次、卡住、跑偏 → `/think-unstuck`
- 新需求或大改动的顺序：主会话实现或 `codex-driven-dev` → `/simplify` → `verify` → `pre-submit-review` → push
- 踩坑复盘、沉淀全局记忆 → `/postmortem`
- 个人 TODO 工作台（跨项目，和项目里的 TASK.md 无关）：用户说「记个 todo / 看 todo / todo 整理」→ Claude Code 用 `/todo` skill；没有 skill 的 agent（如 Codex）直接读写 `~/todos/`：`inbox.md` 只追加速记（`- [ ] MM-DD HH:MM 内容`），`TODO.md` 是看板，整理规则见 `~/.claude/skills/todo/SKILL.md`

## 跨 agent 兼容

- 子任务派发用通用描述，不绑定特定 subagent 名；工具用通用名（Read、Grep、Glob、WebSearch、Edit）
- 路径默认相对仓库根；不支持并行的平台把并行子任务降级为顺序执行
