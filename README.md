# dotfiles

[中文](./README.zh-CN.md)

Share commands, skills, and global agent instructions across 30+ AI coding agents.

## Install

```bash
npx github:notdp/.dotfiles install
```

Interactive installer with two setup modes:

- **Create new** — start with pre-made skills & commands, pick what you need
- **Import existing** — clone your own git repository

## Uninstall

```bash
npx github:notdp/.dotfiles uninstall
```

## Other commands

```bash
npx -y github:notdp/.dotfiles status   # check symlink status
npx -y github:notdp/.dotfiles fix      # merge standalone dirs into dotfiles
```

## What it does

Symlinks a single source directory to every agent's config path:

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

Edit once, apply everywhere.

## Supported Agents

33 agents + 6 universal agents. Full list:

AdaL, Amp, Antigravity, Augment, Claude Code, Cline, CodeBuddy, Codex, Command Code, Continue, Crush, Cursor, Droid, Gemini CLI, GitHub Copilot, Goose, iFlow CLI, Junie, Kilo Code, Kimi Code CLI, Kiro CLI, Kode, MCPJam, Mistral Vibe, Mux, Neovate, OpenClaw, OpenCode, OpenHands, Pi, Pochi, Qoder, Qwen Code, Roo Code, Trae, Windsurf, Zencoder

## Skills

| Skill | Description |
|-------|-------------|
| **[duoduo](./DUODUO.md)** | Cross-review PRs with Opus + Codex |
| **chrome-devtools-mcp-fix** | Fix chrome-devtools MCP connection issues |
| **chrome-devtools-mock** | Mock frontend API data via Chrome DevTools |
| **droid-bin-mod** | Modify droid binary to disable output truncation |
| **find-skills** | Discover and install agent skills |
| **frontend-design** | Create production-grade frontend interfaces |
| **react** | React component development guide |
| **react-best-practices** | React/Next.js performance optimization from Vercel |
| **react-doctor** | Diagnose and fix React codebase health issues |
| **shadcn-ui** | shadcn/ui component library guide |

## Commands

| Command | Description |
|---------|-------------|
| `clip` | Copy content to clipboard |
| `ec` | Edit configuration |
| `eh` | Edit history |
| `install-react-grab` | Install react-grab component |
| `learn` | Learn from codebase patterns |
| `simplify` | Simplify complex code |
