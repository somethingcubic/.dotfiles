#!/usr/bin/env python3
"""SessionStart：按会话目录找到知识库里对应的项目，提示开工前读它的 overview.md 和 status.md。

起因：AGENTS.md 里的读库约定 Codex 会照做，Claude Code 两次实测都没有先读 index 和 overview（2026-10-25）。
只输出路径，不注入笔记内容，读不读仍由任务大小决定。
项目映射复用知识库的 _system/scripts/collect.py（ProjectMapper 读 _system/sources.yaml），这里不另写一份。
对应不到项目、库不存在、无人值守任务的目录（sources.yaml 的 exclude_session_dirs）都不输出。
"""
import importlib.util
import json
import os
import sys

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
    note_dir = os.path.join(VAULT, "projects", key or "")
    files = [os.path.join(note_dir, f) for f in ("overview.md", "status.md")
             if key and os.path.exists(os.path.join(note_dir, f))]
    if not files:
        return 0
    msg = (f"知识库：当前目录对应项目 {key}。非 trivial 任务开工前先读 {' 和 '.join(files)}；"
           f"做决策或碰到旧坑再读同目录的 decisions.md、pitfalls.md。纯问答、<20 行改动不用读。")
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": msg}},
                     ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
