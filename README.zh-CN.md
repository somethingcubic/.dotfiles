# dotfiles

[English](./README.md)

让 30+ AI 编程 Agent 共享 commands、skills 和全局 Agent 指令。

## 安装

```bash
npx github:notdp/.dotfiles install
```

交互式安装器，两种模式：

- **新建** — 从预置 skills & commands 开始，选择需要的
- **导入** — 克隆你自己的 git 仓库

## 卸载

```bash
npx github:notdp/.dotfiles uninstall
```

## 其他命令

```bash
npx -y github:notdp/.dotfiles status   # 检查软链状态
npx -y github:notdp/.dotfiles fix      # 合并独立目录到 dotfiles
```

## 做了什么

将单一源目录软链到每个 agent 的配置路径：

```
~/.claude/skills     → ~/.dotfiles/skills
~/.codex/skills      → ~/.dotfiles/skills
~/.factory/skills    → ~/.dotfiles/skills
~/.claude/commands   → ~/.dotfiles/commands
~/.codex/prompts     → ~/.dotfiles/commands
~/.factory/commands  → ~/.dotfiles/commands
~/.claude/CLAUDE.md  → ~/.dotfiles/agents/AGENTS.md
~/.codex/AGENTS.md   → ~/.dotfiles/agents/AGENTS.md
~/.factory/AGENTS.md → ~/.dotfiles/agents/AGENTS.md
```

改一处，全生效。

## 支持的 Agent

33 个 agent + 6 个 universal agent，完整列表：

AdaL, Amp, Antigravity, Augment, Claude Code, Cline, CodeBuddy, Codex, Command Code, Continue, Crush, Cursor, Droid, Gemini CLI, GitHub Copilot, Goose, iFlow CLI, Junie, Kilo Code, Kimi Code CLI, Kiro CLI, Kode, MCPJam, Mistral Vibe, Mux, Neovate, OpenClaw, OpenCode, OpenHands, Pi, Pochi, Qoder, Qwen Code, Roo Code, Trae, Windsurf, Zencoder

## Skills

| Skill | 说明 |
|-------|------|
| **[duoduo](./DUODUO.md)** | Opus + Codex 交叉审查 PR |
| **chrome-devtools-mcp-fix** | 修复 chrome-devtools MCP 连接问题 |
| **chrome-devtools-mock** | 通过 Chrome DevTools 注入脚本 mock 前端 API 数据 |
| **droid-bin-mod** | 修改 droid 二进制以禁用输出截断 |
| **find-skills** | 发现和安装 agent skills |
| **frontend-design** | 创建生产级前端界面 |
| **react** | React 组件开发指南 |
| **react-best-practices** | Vercel 工程团队的 React/Next.js 性能优化指南 |
| **react-doctor** | 诊断和修复 React 代码库健康问题 |
| **shadcn-ui** | shadcn/ui 组件库指南 |

## Commands

| 命令 | 说明 |
|------|------|
| `clip` | 复制内容到剪贴板 |
| `ec` | 编辑配置 |
| `eh` | 编辑历史 |
| `install-react-grab` | 安装 react-grab 组件 |
| `learn` | 从代码库模式中学习 |
| `simplify` | 简化复杂代码 |
