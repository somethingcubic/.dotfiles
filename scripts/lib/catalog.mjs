export const UNIVERSAL_AGENTS = [
  'Amp', 'Codex', 'Gemini CLI', 'GitHub Copilot', 'Kimi Code CLI', 'OpenCode',
];

export const UNIVERSAL = {
  skills: '~/.agents/skills',
  commands: '~/.agents/commands',
};

export const AGENTS = [
  { name: 'AdaL',         skills: '~/.adal/skills',                    commands: '~/.adal/commands' },
  { name: 'Antigravity',  skills: '~/.agent/skills',                   commands: '~/.agent/commands' },
  { name: 'Augment',      skills: '~/.augment/skills',                 commands: '~/.augment/commands' },
  { name: 'Claude Code',  skills: '~/.claude/skills',                  commands: '~/.claude/commands',                  instructions: '~/.claude/CLAUDE.md' },
  { name: 'Cline',        skills: '~/.cline/skills',                   commands: '~/.cline/commands' },
  { name: 'CodeBuddy',    skills: '~/.codebuddy/skills',               commands: '~/.codebuddy/commands' },
  { name: 'Codex',        skills: '~/.codex/skills',                   commands: '~/.codex/prompts',                   instructions: '~/.codex/AGENTS.md' },
  { name: 'Command Code', skills: '~/.commandcode/skills',             commands: '~/.commandcode/commands' },
  { name: 'Continue',     skills: '~/.continue/skills',                commands: '~/.continue/commands' },
  { name: 'Crush',        skills: '~/.crush/skills',                   commands: '~/.crush/commands' },
  { name: 'Cursor',       skills: '~/.cursor/skills',                  commands: '~/.cursor/commands' },
  { name: 'Droid',        skills: '~/.factory/skills',                 commands: '~/.factory/commands',                 instructions: '~/.factory/AGENTS.md' },
  { name: 'Gemini CLI',   skills: '~/.gemini/antigravity/skills',      commands: '~/.gemini/antigravity/global_workflows' },
  { name: 'Goose',        skills: '~/.goose/skills',                   commands: '~/.goose/commands' },
  { name: 'iFlow CLI',    skills: '~/.iflow/skills',                   commands: '~/.iflow/commands' },
  { name: 'Junie',        skills: '~/.junie/skills',                   commands: '~/.junie/commands' },
  { name: 'Kilo Code',    skills: '~/.kilocode/skills',                commands: '~/.kilocode/commands' },
  { name: 'Kiro CLI',     skills: '~/.kiro/skills',                    commands: '~/.kiro/commands' },
  { name: 'Kode',         skills: '~/.kode/skills',                    commands: '~/.kode/commands' },
  { name: 'MCPJam',       skills: '~/.mcpjam/skills',                  commands: '~/.mcpjam/commands' },
  { name: 'Mistral Vibe', skills: '~/.vibe/skills',                    commands: '~/.vibe/commands' },
  { name: 'Mux',          skills: '~/.mux/skills',                     commands: '~/.mux/commands' },
  { name: 'Neovate',      skills: '~/.neovate/skills',                 commands: '~/.neovate/commands' },
  { name: 'OpenClaw',     skills: '~/skills',                          commands: '~/commands' },
  { name: 'OpenHands',    skills: '~/.openhands/skills',               commands: '~/.openhands/commands' },
  { name: 'Pi',           skills: '~/.pi/skills',                      commands: '~/.pi/commands' },
  { name: 'Pochi',        skills: '~/.pochi/skills',                   commands: '~/.pochi/commands' },
  { name: 'Qoder',        skills: '~/.qoder/skills',                   commands: '~/.qoder/commands' },
  { name: 'Qwen Code',    skills: '~/.qwen/skills',                    commands: '~/.qwen/commands' },
  { name: 'Roo Code',     skills: '~/.roo/skills',                     commands: '~/.roo/commands' },
  { name: 'Trae',         skills: '~/.trae/skills',                    commands: '~/.trae/commands' },
  { name: 'Windsurf',     skills: '~/.windsurf/skills',                commands: '~/.windsurf/commands' },
  { name: 'Zencoder',     skills: '~/.zencoder/skills',                commands: '~/.zencoder/commands' },
];

export function allSkillPaths() {
  return [UNIVERSAL.skills, ...AGENTS.map(a => a.skills)];
}

export function allCommandPaths() {
  return [UNIVERSAL.commands, ...AGENTS.map(a => a.commands)];
}

export function allAgentPaths() {
  return AGENTS.filter(a => a.instructions).map(a => a.instructions);
}

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

export function detectDotfilesDir() {
  const HOME = os.homedir();
  const expand = (s) => (s === '~' ? HOME : s.startsWith('~/') ? path.join(HOME, s.slice(2)) : s);
  const votes = {};
  for (const p of allSkillPaths()) {
    const full = expand(p);
    try {
      if (fs.lstatSync(full).isSymbolicLink()) {
        const dir = fs.readlinkSync(full).replace(/\/skills$/, '');
        votes[dir] = (votes[dir] || 0) + 1;
      }
    } catch {}
  }
  let best = null;
  let max = 0;
  for (const [dir, count] of Object.entries(votes)) {
    if (count > max) { best = dir; max = count; }
  }
  return best;
}
