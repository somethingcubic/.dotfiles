# TASK: 按「少用子 Agent」调整本地工作流（2026-10-23，已完成）

依据：Anthropic 2026-10-22「Building agents: When to fold subagents into your main agent loop」。分支 `feat/agent-spawn-rules`。

- [x] 1. evals/：无头 eval（E1–E4）、run.sh、check.py、usage_stats.py；改前基线 12/12（$6.53），常驻上下文中位 65k token
- [x] 2. hooks/secret-print-guard.py（PreToolUse Bash|Read）+ 162 个用例；已注册并在会话里实测；lessons 删了被覆盖的 3 条，AGENTS.md 红线 A 补文字版给 Codex
- [x] 3. AGENTS.md「要不要开子 agent」替换「按体量选做法」，fork 规则改写，第 65 行隔离说法统一
- [x] 4. agent-model-gate.sh / workflow-model-gate.mjs 要求类型标签 + 测试
- [x] 5. 清理：skillOverrides 关 cross-review、hive；skill-routing.md 删失效条目；per-turn-conduct.md 移到 agents/；prod-safety 拒绝信息
- [x] 6. 两轮独立审查：第 1 轮 18 项、第 2 轮 1 个高危（任意位置的 X=$(...) 被当成赋值删掉）和若干中低项，全部修进本分支并补用例
- [x] 7. 改后 eval 12/12（$6.34），没有翻转；8 组 hook 测试全过；测试用例里的内部路径和键名换成通用名字（仓库公开）

不在 git 里的改动（改前备份在会话 scratchpad）：~/.claude/settings.json（注册 hook、关两个 skill、per-turn 路径），~/.claude/lessons.md（删 3 条）。

结论与局限：
- 这套 eval 改前改后都是 12/12，只能发现变差，测不出变好；E2 三次都是主会话串行修完，隔离规则没被用到。
- 回放 30 天涉及 env 的 2068 条历史命令：35 条实测会打印口令、19 条 source；当时目录还在、按严格规则拦的 138 条（多为远程按前缀查，要先 cut -d= -f1 再点名），约每天 4 次改写。
- 已知不拦：python/node 脚本读 env、日志里 URL 查询串带的 key、取进变量后再 echo、经变量间接引用文件名。
