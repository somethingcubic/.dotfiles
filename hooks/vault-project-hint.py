#!/usr/bin/env python3
"""SessionStart / SubagentStart：按会话目录找到知识库里对应的项目，注入该项目被纠正后定下的规则（projects/<key>/rules.md），
主会话另外提示开工前读 overview.md 和 status.md。

起因：AGENTS.md 里的读库约定 Codex 会照做，Claude Code 两次实测都没有先读 index 和 overview（2026-10-25）。
项目规则从 lessons.md 迁到知识库后（2026-10-26），只在对应项目的会话里注入。
SessionStart 注入的内容不会传给子 agent（2026-10-26 实测），所以同一脚本也挂 SubagentStart，子 agent 只注入规则。
overview、status 只给路径，读不读由任务大小决定。
项目映射复用知识库的 _system/scripts/collect.py（ProjectMapper 读 _system/sources.yaml），这里不另写一份。
对应不到项目、库不存在、无人值守任务的目录（sources.yaml 的 exclude_session_dirs）都不输出。
"""
import importlib.util
import json
import os
import sys

MAX_RULES_CHARS = 6000
VAULT = os.environ.get("AGENT_VAULT_DIR") or os.path.expanduser("~/Documents/AgentVault")


def project_for(cwd):
    path = os.path.join(VAULT, "_system", "scripts", "collect.py")
    if not os.path.exists(path):
        return None
    spec = importlib.util.spec_from_file_location("vault_collect", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    mapper = mod.ProjectMapper(mod.load_config())
    if mapper.excluded(cwd):
        return None
    key = mapper.key_for_cwd(cwd)
    return None if key == "misc" else key


def rules_body(path):
    """去掉 frontmatter 后的正文；超长时截断并注明去读原文件。"""
    if not os.path.exists(path):
        return ""
    with open(path, encoding="utf-8") as f:
        text = f.read()
    if text.startswith("---\n"):
        end = text.find("\n---", 4)
        text = text[end + 4:] if end > 0 else text
    text = text.strip()
    if len(text) > MAX_RULES_CHARS:
        text = text[:MAX_RULES_CHARS] + f"\n…（超过 {MAX_RULES_CHARS} 字已截断，完整内容读 {path}）"
    return text


def main():
    try:
        event = json.load(sys.stdin)
    except json.JSONDecodeError:
        return 0
    cwd = event.get("cwd") or os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()
    try:
        key = project_for(cwd)
    except Exception as e:  # 库里的配置或脚本出错时不挡会话启动，只在 stderr 留一行
        print(f"vault-project-hint: {e}", file=sys.stderr)
        return 0
    if not key:
        return 0
    event_name = event.get("hook_event_name") or "SessionStart"
    note_dir = os.path.join(VAULT, "projects", key)
    parts = []
    if event_name == "SessionStart":
        files = [os.path.join(note_dir, f) for f in ("overview.md", "status.md")
                 if os.path.exists(os.path.join(note_dir, f))]
        if files:
            parts.append(f"知识库：当前目录对应项目 {key}。非 trivial 任务开工前先读 {' 和 '.join(files)}；"
                         f"做决策或碰到旧坑再读同目录的 decisions.md、pitfalls.md。纯问答、<20 行改动不用读。")
    rules = rules_body(os.path.join(note_dir, "rules.md"))
    if rules:
        parts.append(f"项目 {key} 被纠正后定下的规则（{os.path.join(note_dir, 'rules.md')}），和 lessons.md 一样要遵守：\n{rules}")
    if not parts:
        return 0
    print(json.dumps({"hookSpecificOutput": {"hookEventName": event_name, "additionalContext": "\n\n".join(parts)}},
                     ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
