# 2026-07-21 全局 AGENTS.md/CLAUDE.md Checkup 执行记录

审计：14-agent workflow（5 lens + 官方文档 lens + 8 对抗复核全成立），报告见 /tmp/agents-md-checkup-20260721.md

## 已完成

**A 安全**
- settings.json 删 10 条含生产 RDS 密码明文的死 allow 条目（102→92）；删 7 个含密码备份文件；~134 个转录/历史文件密码原地脱敏（本 session 转录会后需再清；密码轮换待用户在阿里云侧执行）
- block-main-commit.sh 重写：git -C 无条件 deny、commit/merge/push 正则容错（含 `-c k=v` option-arg 形态）、`cd <path> &&` 前缀跟随、unborn HEAD 修复、compound 命令中段 git 也检测（原 `^\s*git` 只查行首）
- prod-safety.sh 增 Rule 1.5：生产 host mysql DML → permissionDecision "ask" 强制人工确认（堵 allow glob 放行 DELETE 子查询的缺口）
- 新增 cmd-guards.sh：SSH 必带 ConnectTimeout（deny）+ 已知 host 并发 ≥3 deny；go test ./... 全量 deny（FULLTEST=1 逃生门）；git push / gh pr create 校验 pre-submit-review marker（.git/presubmit-ok == HEAD，PRESUBMIT_SKIP=1 逃生门）
- 27 case 测试矩阵全过（deny/pass/ask 双向断言，含回归）

**B 死链**
- @RTK.md import 删除，~/.claude/RTK.md → ~/.claude/archive/（rtk 已卸载）
- skill-routing.md：删 qiushi-skill 10 条死路由、删与入口重复的硬触发节和体量表；4 个已停用 skill（spec-driven-dev/prd-writer/tech-spec-writer/release-note-writer）标注停用
- AGENTS.md 内 `.claude/rules/` 相对路径 → `~/.claude/rules/` 绝对形式
- ~/.codex/rules/ 补 commit-style.md、response-style.md 软链（6/6 对齐）
- safety.md 删无效 `globs:` frontmatter key（官方 key 是 paths；且 safety 属命令场景不宜 path-scope，明示刻意常驻）

**D 冗余收敛（常驻 ~33.5KB → ~24KB）**
- AGENTS.md 144→~119 行：D 节/事故排查节/验证表压为指针（SoT 分别为 db-boundary skill、pipeline-debug-protocol skill、verify skill）
- debugging-discipline.md（90 行）rules → skills/debugging-discipline（按需加载；三端 skills 目录软链同源一次覆盖）
- truth-directive.md 78→~50 行：删禁用词/核心原则重复节（入口一行式为准，"引用原文除外"已并入），锚点节压缩指向 pre-submit-review §4
- 教训锚点收敛：补 5 篇 postmortem（03-12 ssh 僵尸/03-30 tags 开关/03-31 git -C/04-22 YT 积压/04-28 伪造锚点），各常驻文件压为一句+指针
- auto-skills.sh 委派策略注入移除（与 AGENTS.md 工作模式重复），脚本改名 .disabled

**E 矛盾修正**
- PR 红线加 scope：限生产/业务仓库，~/.dotfiles 本地直推与 bot sync 明示为既定例外
- response-style.md /tmp 规则改为"有 scratchpad 优先 scratchpad，无（Codex）落 /tmp"
- 事故排查触发范围对齐：pipeline 类走 pipeline-debug-protocol，通用 bug 走 debugging-discipline 分诊

## 残留项（未做，需后续决策）

- 密码轮换（用户在阿里云 RDS 侧操作）+ 本 session 转录文件会后脱敏
- Codex 侧 hook 能力未验证（安全 hook 仅 CC 生效；Codex 目前靠 prose 红线）
- ~/.claude/hooks/ 未纳入 dotfiles 版本控制
- 多 Agent 协作节暂留入口未迁 codex-driven-dev（Codex 等效加载未验证）
- D1 深度去重（safety.md 与入口 A 节的规则句复述）仅做轻量处理，待 Codex rules 加载机制确认后可再压
- skillOverrides 4 个停用 skill 是否重新启用
