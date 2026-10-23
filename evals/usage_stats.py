#!/usr/bin/env python3
"""usage_stats.py — 从 ~/.claude/projects 的 transcript 统计子 agent 和 workflow 的使用情况，只输出计数。

  python3 -I evals/usage_stats.py [--days 14] [--out evals/results/<label>-usage.json]

指标（窗口按记录 timestamp 截取，UTC）：
  - resident_tokens：窗口内开始的主会话，第一条回复的 input + 缓存写 + 缓存读 token，即常驻上下文大小
  - 主会话发出的 Agent / Workflow 调用，按 description 开头的类型标签分组
  - 窗口内开始的子 agent 里，改过仓库代码文件的个数（scratchpad、/tmp、~/.claude 下的不算）
  - 发生过压缩的主会话数
时间窗口不同的两次结果只作描述，不据此说变好或变差。
"""
import argparse
import collections
import datetime
import glob
import json
import os
import re
import statistics

ROOT = os.path.expanduser("~/.claude/projects")
TAG = re.compile(r"^\s*\[(并行只读|独立验证|大范围读取|并行修复)\]")
WF_TAG = re.compile(r"description\s*:\s*['\"`]\s*\[(并行只读|独立验证|大范围读取|并行修复)\]")
EDIT_TOOLS = {"Edit", "Write", "MultiEdit", "NotebookEdit"}
CODE_EXT = re.compile(r"\.(go|ts|tsx|js|mjs|py|sh|sql|vue|css|yml|yaml|toml)$")


def records(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            try:
                yield json.loads(line)
            except json.JSONDecodeError:
                continue


def tool_uses(rec):
    if rec.get("type") != "assistant":
        return
    for c in (rec.get("message") or {}).get("content") or []:
        if isinstance(c, dict) and c.get("type") == "tool_use":
            yield c


def pct(vals, q):
    if not vals:
        return None
    vals = sorted(vals)
    return vals[min(len(vals) - 1, int(round(q * (len(vals) - 1))))]


def is_repo_code(path):
    if not CODE_EXT.search(path):
        return False
    if "scratchpad" in path or re.match(r"/(private/)?tmp/", path):
        return False
    return not ("/.claude/" in path and "/worktrees/" not in path)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--days", type=int, default=14)
    ap.add_argument("--out")
    args = ap.parse_args()
    now = datetime.datetime.now(datetime.timezone.utc)
    lo = (now - datetime.timedelta(days=args.days)).strftime("%Y-%m-%dT%H:%M:%S")
    hi = now.strftime("%Y-%m-%dT%H:%M:%S")

    resident, spawn = [], collections.Counter()
    sessions = compacted = 0
    for path in glob.glob(os.path.join(ROOT, "*", "*.jsonl")):
        if os.path.getmtime(path) < (now - datetime.timedelta(days=args.days)).timestamp():
            continue
        first_ts, first_usage, teammate, seen, comp = None, None, False, False, False
        for r in records(path):
            ts = r.get("timestamp") or ""
            if r.get("teamName"):
                teammate = True
                break
            if first_ts is None and ts:
                first_ts = ts
            if not (lo <= ts <= hi):
                continue
            seen = True
            if r.get("isCompactSummary") or (r.get("type") == "system" and r.get("subtype") == "compact_boundary"):
                comp = True
            usage = (r.get("message") or {}).get("usage") if r.get("type") == "assistant" else None
            if usage and first_usage is None:
                first_usage = usage
            for c in tool_uses(r):
                inp = c.get("input") or {}
                if c.get("name") == "Agent":
                    spawn["agent"] += 1
                    if inp.get("subagent_type") == "fork":
                        spawn["agent_fork"] += 1
                    if inp.get("isolation") == "worktree":
                        spawn["agent_worktree"] += 1
                    m = TAG.match(inp.get("description") or "")
                    spawn["agent_tag:" + (m.group(1) if m else "无标签")] += 1
                elif c.get("name") == "Workflow":
                    spawn["workflow"] += 1
                    m = WF_TAG.search(inp.get("script") or "")
                    spawn["workflow_tag:" + (m.group(1) if m else "无标签或按路径调用")] += 1
        if teammate or not seen:
            continue
        sessions += 1
        compacted += comp
        if first_usage and first_ts and first_ts >= lo:
            size = sum(first_usage.get(k) or 0 for k in
                       ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"))
            if size:  # 0 是第一次请求失败的会话
                resident.append(size)

    subagents = collections.Counter()
    for kind, pattern in (("agent", "*/*/subagents/agent-*.jsonl"),
                          ("workflow", "*/*/subagents/workflows/wf_*/agent-*.jsonl")):
        for path in glob.glob(os.path.join(ROOT, pattern)):
            recs = records(path)
            first = next((r.get("timestamp") for r in recs if r.get("timestamp")), None)
            if not first or not (lo <= first <= hi):
                continue
            subagents[kind] += 1
            for r in records(path):
                if any(c.get("name") in EDIT_TOOLS and is_repo_code(
                        (c.get("input") or {}).get("file_path") or "") for c in tool_uses(r)):
                    subagents[kind + "_repo_code_edit"] += 1
                    break

    out = {
        "window_utc": [lo, hi],
        "main_sessions": sessions,
        "compacted_main_sessions": compacted,
        "resident_tokens": {
            "sessions": len(resident),
            "median": statistics.median(resident) if resident else None,
            "p90": pct(resident, 0.9),
            "min": min(resident) if resident else None,
        },
        "spawn_calls": dict(sorted(spawn.items())),
        "subagents": dict(sorted(subagents.items())),
    }
    text = json.dumps(out, ensure_ascii=False, indent=2)
    print(text)
    if args.out:
        with open(args.out, "w", encoding="utf-8") as f:
            f.write(text + "\n")


if __name__ == "__main__":
    main()
