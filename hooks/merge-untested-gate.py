#!/usr/bin/env python3
"""merge-untested-gate.py — PreToolUse(Bash|mcp__github__merge_pull_request)：往 OrdoAI/ordo-platform 的 pre / main 合并 PR 前，PR 描述必须写清「未验证」。

起因：2026-11-06 #1501 的「AI 回信归属」读信 SQL 查了不存在的列，上线后每分钟报错、合作单不推进。11-03 会话已经告诉
用户「定时扫描在 fund-pay，AI 回信归因这次测不了」，PR 的 Validation 却把「回信归属」写在集成测试下，没写测试环境没跑过；
之后会话照常合进 pre、随发布单上了生产。lessons 10-08 / 11-02 已有「用户同意发布 ≠ 接受某个遗留未知，分开问」，这是再犯，改成 hook。

规则（只管 Bash 里的 `gh pr merge` 和 GitHub MCP 的 merge_pull_request，仓库是 OrdoAI/ordo-platform、base 是 pre 或 main 的合并）：
  1. PR 描述里要有「未验证」小节（标题 `## 未验证`，也认 `## Untested`）。没有 → 拦。
  2. 小节只有一行、以「无」（或 None）开头 → 放行。
  3. 列了项的，每一项都要写「用户 YYYY-MM-DD 确认接受」。有一项没写 → 拦。
放行：head 是 main（main→pre 同步）或 candidate/*（发布单）；别的仓库；`--disable-auto`、`--help`。
取 PR 信息用 `gh pr view`；gh 调用失败时拦下（合并本来就要用户批准，宁可拦）。解析器自身出错时放行，和其他 hook 一致。
已知不拦：`gh api .../pulls/<n>/merge`、GitHub 网页上点合并。
用例见 hooks/tests/merge-untested-gate.test.sh。
"""
import json
import os
import re
import shlex
import subprocess
import sys

TARGET_REPO = "ordoai/ordo-platform"
MCP_MERGE = "mcp__github__merge_pull_request"
GATED_BASES = {"pre", "main"}
# gh pr merge 里带参数值的选项（值不是 PR 号）
VALUE_FLAGS = {"-R", "--repo", "-t", "--subject", "-b", "--body", "-F", "--body-file",
               "--match-head-commit", "-A", "--author-email"}
SECTION = re.compile(r"^(#{1,6})\s*(未验证|untested)\b.*$", re.I)
HEADING = re.compile(r"^(#{1,6})\s+\S")
LIST_ITEM = re.compile(r"^( {0,1})(?:[-*+]|\d+[.)])\s+(.*)$")
CONFIRM = re.compile(r"用户\s*\d{4}-\d{2}-\d{2}\s*确认接受")
NONE_LINE = re.compile(r"^(无|none|n/a)([。.，,；;（(：:\s].*)?$", re.I)
PR_URL = re.compile(r"github\.com/([^/\s]+/[^/\s]+)/pull/(\d+)", re.I)
RULE = ("规则：合进 OrdoAI/ordo-platform 的 pre / main 前，PR 描述要有「## 未验证」小节，"
        "写清哪些功能点没在测试环境端到端跑过；没有就写「无」；列了的每一项都要写「用户 YYYY-MM-DD 确认接受」。")
HOWTO = ("怎么补：① 在 PR 描述里加「## 未验证」小节（gh pr edit <n> --body-file …）；"
         "② 有未验证项时，逐条问用户「补测还是接受」，写清怎样能测和代价（例如接管测试环境的定时扫描任务组），"
         "用户确认接受的项写上「用户 YYYY-MM-DD 确认接受」，要补测的先测完再合。")


def merge_args(cmd):
    """返回 (gh pr merge 之后的参数列表, 命令里 `cd <dir>` 的目录)；不是合并命令返回 (None, None)。"""
    try:
        toks = shlex.split(cmd, posix=True)
    except ValueError:
        toks = cmd.split()
    cd_dir = None
    for i, t in enumerate(toks):
        if t == "cd" and i + 1 < len(toks):
            cd_dir = toks[i + 1]
        if t == "gh" and toks[i + 1:i + 3] == ["pr", "merge"]:
            rest = []
            for a in toks[i + 3:]:
                if a in {"&&", "||", ";", "|"} or a.endswith(";"):
                    break
                rest.append(a)
            return rest, cd_dir
    return None, None


def parse_target(args):
    repo, pr, skip = None, None, False
    for i, a in enumerate(args):
        if skip:
            skip = False
            continue
        if a in {"--help", "-h", "--disable-auto"}:
            return None, None, True
        if a in VALUE_FLAGS:
            if a in {"-R", "--repo"} and i + 1 < len(args):
                repo = args[i + 1]
            skip = True
            continue
        if a.startswith("--repo="):
            repo = a.split("=", 1)[1]
            continue
        if a.startswith("-"):
            continue
        if pr is None:
            m = PR_URL.search(a)
            if m:
                repo, pr = m.group(1), m.group(2)
            else:
                pr = a
    return repo, pr, False


def remote_repo(cwd):
    try:
        url = subprocess.run(["git", "remote", "get-url", "origin"], cwd=cwd, capture_output=True,
                             text=True, timeout=5).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return None
    m = re.search(r"github\.com[:/]([^/\s]+/[^/\s]+?)(?:\.git)?/?$", url)
    return m.group(1) if m else None


def normalize(repo):
    return re.sub(r"\.git$", "", (repo or "").strip().lower()).replace("https://github.com/", "")


def section_items(body):
    """返回 None（没有小节）或小节里的条目列表（空列表 = 写了「无」）。"""
    lines = (body or "").replace("\r\n", "\n").split("\n")
    body_no_comments = re.sub(r"<!--.*?-->", "", "\n".join(lines), flags=re.S).split("\n")
    start, level = None, 0
    for i, ln in enumerate(body_no_comments):
        m = SECTION.match(ln.strip())
        if m:
            start, level = i + 1, len(m.group(1))
            break
    if start is None:
        return None
    content = []
    for ln in body_no_comments[start:]:
        h = HEADING.match(ln.strip())
        if h and len(h.group(1)) <= level:
            break
        if ln.strip():
            content.append(ln.rstrip())
    if not content:
        return ["（小节是空的）"]
    if len(content) == 1 and NONE_LINE.match(content[0].strip().lstrip("-*+ ").strip()):
        return []
    items = []
    for ln in content:
        m = LIST_ITEM.match(ln)
        if m or not items:
            items.append((m.group(2) if m else ln).strip())
        else:
            items[-1] += " " + ln.strip()
    return items


def check(cmd, cwd):
    args, cd_dir = merge_args(cmd)
    if args is None:
        return None
    repo, pr, exempt = parse_target(args)
    if exempt:
        return None
    if cd_dir:
        cwd = cd_dir if os.path.isabs(cd_dir) else os.path.join(cwd, os.path.expanduser(cd_dir))
    if not repo:
        repo = remote_repo(cwd)
    return check_pr(repo, pr, cwd)


def check_pr(repo, pr, cwd):
    if normalize(repo) != TARGET_REPO:
        return None
    view = ["gh", "pr", "view"] + ([pr] if pr else []) + ["--repo", "OrdoAI/ordo-platform",
                                                          "--json", "number,baseRefName,headRefName,body"]
    try:
        out = subprocess.run(view, cwd=cwd if os.path.isdir(cwd) else None, capture_output=True,
                             text=True, timeout=30)
    except (OSError, subprocess.SubprocessError) as e:
        return "读不到 PR 信息（%s），按规则先拦下。网络恢复后重试；急着合就请用户自己合。" % e
    if out.returncode != 0:
        return "读不到 PR 信息（gh pr view 退出码 %d：%s），按规则先拦下。" % (
            out.returncode, (out.stderr or out.stdout).strip()[:200])
    try:
        info = json.loads(out.stdout)
    except ValueError:
        return "gh pr view 的输出不是 JSON，按规则先拦下。"
    base, head, num = info.get("baseRefName", ""), info.get("headRefName", ""), info.get("number", pr)
    if base not in GATED_BASES or head == "main" or head.startswith("candidate/"):
        return None
    items = section_items(info.get("body", ""))
    if items is None:
        return "PR #%s（%s → %s）的描述里没有「未验证」小节。%s %s" % (num, head, base, RULE, HOWTO)
    missing = [it for it in items if not CONFIRM.search(it)]
    if missing:
        listed = "；".join("「%s」" % m[:80] for m in missing)
        return "PR #%s（%s → %s）的「未验证」小节里有 %d 项没写用户确认：%s。%s %s" % (
            num, head, base, len(missing), listed, RULE, HOWTO)
    return None


def main():
    try:
        data = json.load(sys.stdin)
    except (ValueError, OSError):
        return 0
    tool, ti = data.get("tool_name"), data.get("tool_input") or {}
    cwd = data.get("cwd") or os.getcwd()
    try:
        if tool == "Bash":
            cmd = ti.get("command") or ""
            if "gh" not in cmd or "merge" not in cmd:
                return 0
            reason = check(cmd, cwd)
        elif tool == MCP_MERGE:
            num = ti.get("pullNumber") or ti.get("pull_number")
            reason = check_pr("%s/%s" % (ti.get("owner", ""), ti.get("repo", "")), str(num) if num else None, cwd)
        else:
            return 0
    except Exception:  # 解析器自身出错时放行，和其他 hook 一致
        return 0
    if not reason:
        return 0
    sys.stderr.write("merge-untested-gate: %s\n" % reason)
    return 2


if __name__ == "__main__":
    sys.exit(main())
