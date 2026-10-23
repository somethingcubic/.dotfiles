#!/usr/bin/env python3
"""secret-print-guard.py — PreToolUse(Bash|Read)：拦下会把 env 口令、浏览器 cookie、进程环境变量打印进会话的操作。

起因：lessons 记了 5 次凭据进会话（2026-10-14 DSN 整行、10-16 cookies get、10-19 source .env、10-21 git grep .env.prod，
以及 10-15 日志里的 access_key）。规则照 lessons 10-21：按前缀 grep env 先 cut -d= -f1 只看键名，要看值的键逐个点名。

env 文件：.env、.env.*、*.env、.envrc（.example/.sample/.template/.dist 模板和 .go/.ts 等代码文件除外）。
判定以「env 内容流到了会话输出」为准，对每段输出 env 内容的命令按顺序判断：
  1. source / . 一律拦。
  2. 最后一段的标准输出写进了文件，放行。
  3. 管道里有一段只输出键名：cut -d= -f1、sed 's/=.*//'、awk -F= '{print $1}'、grep -c/-l/-L/-q、wc、
     grep -o 一个以 ^ 开头且匹配不过 = 的模式。放行。
  4. 能拿到内容的（本机文件、本机仓库里 git 版本的文件）：hook 按这次 grep / sed -n 的选择规则（含 -A/-B/-C 上下文）
     算出会被打印的行，里面有口令就拦，没有就放行。口令：键名含 SECRET/PASS/TOKEN/KEY/SK/BEARER 等，
     值是 user:pass@ 连接串，或值是 24 位以上的随机串（*_ID 除外）。
  5. 拿不到内容的（远程、git diff/log -p 的补丁）：grep 的模式全是以 ^ 开头的确切非敏感键（^KEY=、^(A|B)=，可带取值部分），
     且不带上下文选项，放行；远程额外把 *_URL、*_URI、*PROXY* 当敏感。
  6. 其余拦下。
另外：/proc/<pid>/environ 只在打印类命令里算；agent-browser cookies（默认就是 get）要只取 name；
git show/diff/log -p/grep 不带路径时，用 git 查这次会不会涉及仓库里的 env 文件；grep -r 会扫目录里的 env 文件。
ssh、bash -c、eval、喂给 bash/ssh 的 heredoc 和 echo … | bash 递归检查（ssh 按远程处理）。
值进变量（VAR=$(...)）、写进文件的 heredoc 不算输出。解析器自身出错时放行（和其他 hook 一致）。
已知不拦：python/node 等脚本里读 env 文件；日志行里 URL 查询串带的 key；给 agent 用的变量再 echo 出来。
用例见 hooks/tests/secret-print-guard.test.sh。
"""
import fnmatch
import glob
import json
import os
import re
import shlex
import subprocess
import sys

ENV_BASENAME = re.compile(r"^(\.env(\.[A-Za-z0-9_-]+)*|[\w.*-]+\.env|\.envrc)\*?$")
TEMPLATE = re.compile(r"\.(example|sample|template|dist|tmpl)(\.env)?\*?$")
CODE_EXT = re.compile(r"\.(go|ts|tsx|js|mjs|cjs|py|rb|sh|md|json|ya?ml|toml|lock)$")
PROC_ENVIRON = re.compile(r"/proc/\S*/environ")
SUB_BODY = re.compile(r"[^()]*\)")
# 命令开头的赋值（可带 export/local 等前缀和前面的其他赋值）：NAME=$(...) 或 NAME="$(...)" 是取值进变量
ASSIGN_BEFORE = re.compile(
    r"(?:^|[;&|\n({]|(?:^|\s)(?:then|do|else|export|local|readonly|declare|typeset)\s)\s*"
    r"(?:[A-Za-z_]\w*=[^\s;&|]*\s+)*[A-Za-z_]\w*=\"?$")
SENSITIVE_KEY = re.compile(
    r"SECRET|PASS|PWD|DSN|CRED|PRIVATE|COOKIE|BEARER|JWT|APIKEY|API_KEY|WEBHOOK|SESSION"
    r"|TOKEN(?!_(LIMIT|TTL|BUCKET|RATE|COUNT|CONCURRENCY|MAX|MIN|BUDGET|QUOTA))|(^|_)(SK|AK|KEY|KEYS|AUTH)(_|$)", re.I)
REMOTE_SENSITIVE_KEY = re.compile(r"URL|URI|PROXY", re.I)
SENSITIVE_VALUE = re.compile(r"://[^/\s@]*:[^@/\s]+@|password=", re.I)
SENSITIVE_TEXT = re.compile(r"pass|pwd|secret|token|key|dsn|\.\*|\.\+", re.I)
PRINTERS = {"cat", "bat", "less", "more", "head", "tail", "nl", "tac", "strings", "xxd", "od", "hexdump",
            "diff", "colordiff", "sdiff", "sort", "uniq", "paste", "column", "tr", "fold", "rev"}
WHOLE_FILE = {"cat", "bat", "head", "tail", "nl", "tac", "sort", "uniq", "less", "more"}
GREPS = {"grep", "egrep", "fgrep", "rg", "ag", "ack"}
ENVIRON_READERS = PRINTERS | GREPS | {"sed", "awk", "gawk", "mawk", "cut", "xargs"}
NON_PRINTING = {"cp", "mv", "ls", "stat", "wc", "touch", "chmod", "rm", "test", "[", "file", "docker", "ln", "realpath"}
SHELLS = {"bash", "sh", "zsh", "ksh", "dash"}
KEYWORDS = {"do", "then", "else", "elif", "{", "(", "!", "if", "while", "until"}
PREFIX_ARGS = {  # 包装命令及其带参数的选项
    "sudo": {"-u", "-g", "-C", "-h", "-p", "-r", "-t", "-U", "-D", "--user", "--group"},
    "timeout": {"-s", "-k", "--signal", "--kill-after"}, "gtimeout": {"-s", "-k", "--signal", "--kill-after"},
    "nice": {"-n"}, "env": {"-u", "-S", "-C", "--unset", "--chdir"}, "stdbuf": {"-i", "-o", "-e"},
    "doas": {"-u"}, "npx": {"-p", "--package"}, "bunx": set(),
    "command": set(), "nohup": set(), "exec": set(), "builtin": set(), "time": set(),
}
SSH_OPT_ARG = set("BbcDEeFIiJLlmOopQRSWw")
GREP_ARG_FLAGS = {"-m", "-A", "-B", "-C", "-f", "--max-count", "--context", "--after-context", "--before-context",
                  "-g", "--glob", "--iglob", "-t", "--type", "--exclude", "--include", "--exclude-dir", "-e", "--regexp"}
STAT_FLAGS = {"--stat", "--name-only", "--name-status", "--numstat", "--shortstat"}
POSIX_CLASSES = {"[:space:]": r"\s", "[:alpha:]": "a-zA-Z", "[:digit:]": "0-9", "[:alnum:]": "a-zA-Z0-9",
                 "[:upper:]": "A-Z", "[:lower:]": "a-z", "[:punct:]": r"!-/:-@\[-`{-~"}
SKIP_DIRS = {".git", "node_modules", "vendor", "dist", "build", ".venv", "venv", "__pycache__", "target", ".next"}

HOWTO = ("看有哪些键：grep -o '^[A-Za-z_][A-Za-z0-9_]*=' <文件>，或接 | cut -d= -f1；"
         "看非敏感键的值：逐个点名 grep -E '^(KEY_A|KEY_B)=' <文件>；"
         "要用口令类的值：VAR=$(grep -m1 '^KEY=' <文件> | cut -d= -f2-)，之后只在命令里用 \"$VAR\"（例如 MYSQL_PWD=\"$VAR\" mysql ...），"
         "不 echo、不打印。确实要看值时请用户自己执行。")


# ── 切分 ──────────────────────────────────────────────────────────────

def split_unquoted(s, seps):
    """按不在引号里的分隔符切分；seps 按长度从长到短排。"""
    out, cur, quote, i = [], [], None, 0
    while i < len(s):
        c = s[i]
        if quote:
            cur.append(c)
            if c == "\\" and quote == '"' and i + 1 < len(s):
                cur.append(s[i + 1])
                i += 1
            elif c == quote:
                quote = None
            i += 1
            continue
        if c in "'\"":
            quote = c
            cur.append(c)
            i += 1
            continue
        if c == "\\" and i + 1 < len(s):
            cur.extend(s[i:i + 2])
            i += 2
            continue
        for sep in seps:
            if s.startswith(sep, i):
                out.append("".join(cur))
                cur = []
                i += len(sep)
                break
        else:
            cur.append(c)
            i += 1
    out.append("".join(cur))
    return [p for p in (x.strip() for x in out) if p]


def unquoted_heredocs(line):
    """一行里不在引号中的 heredoc 开头：返回 [(<< 之前的文字, 结束标记)]。"""
    out, quote, i = [], None, 0
    while i < len(line):
        c = line[i]
        if quote:
            if c == "\\" and quote == '"':
                i += 1
            elif c == quote:
                quote = None
        elif c in "'\"":
            quote = c
        elif c == "\\":
            i += 1
        elif line.startswith("<<", i) and not line.startswith("<<<", i) and (i == 0 or line[i - 1] != "<"):
            m = re.match(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1", line[i:])
            if m:
                out.append((line[:i], m.group(2)))
                i += m.end()
                continue
        i += 1
    return out


def split_heredocs(cmd):
    """去掉 heredoc 正文；返回 (去掉正文的命令, [(<< 之前的文字, 正文)])。"""
    out, bodies, pending, cur = [], [], [], []
    for line in cmd.split("\n"):
        if pending:
            if line.strip() == pending[0][1]:
                bodies.append((pending[0][0], "\n".join(cur)))
                pending.pop(0)
                cur = []
            else:
                cur.append(line)
            continue
        out.append(line)
        pending.extend(unquoted_heredocs(line))
    return "\n".join(out), bodies


def resolve_substitutions(command, cwd, depth):
    """处理 $(...)、`...`、<(...)、>(...)，从最内层开始。命令开头赋值里的 $(...) 是取值进变量，不检查；
    其余的先单独检查里面的命令（它的输出会成为参数或被打印），再换成占位符，免得把外层的词切开。
    单引号里的不展开、原样保留（ssh 的远程命令串由递归检查处理）。返回 (处理后的命令, 原因)。"""
    while True:
        out, i, quote, changed, n = [], 0, None, False, len(command)
        while i < n:
            c = command[i]
            if quote == "'":
                out.append(c)
                quote = None if c == "'" else quote
                i += 1
                continue
            if c == "\\" and i + 1 < n:
                out.append(command[i:i + 2])
                i += 2
                continue
            if c in "'\"" and quote in (None, c):
                quote = None if quote == c else c
                out.append(c)
                i += 1
                continue
            if c == "`":
                j = command.find("`", i + 1)
                if j < 0:
                    out.append(c)
                    i += 1
                    continue
                inner, end, kind = command[i + 1:j], j + 1, "cmd"
            elif command.startswith("$(", i) or (quote is None and c in "<>" and command.startswith("(", i + 1)):
                m = SUB_BODY.match(command, i + 2)
                if not m:  # 里面还有括号，下一轮等内层先换掉
                    out.append(c)
                    i += 1
                    continue
                inner, end, kind = command[i + 2:m.end() - 1], m.end(), ("proc" if c in "<>" else "cmd")
            else:
                out.append(c)
                i += 1
                continue
            pre = ("\x00" if i > 300 else "") + command[max(0, i - 300):i]
            captured = kind == "cmd" and ASSIGN_BEFORE.search(pre) and (quote is None or pre.endswith('"'))
            if not captured:
                reason = analyze(inner, cwd, depth + 1)
                if reason:
                    return command, reason
            out.append("/dev/fd/63" if kind == "proc" else "$SUB")
            i, changed = end, True
        command = "".join(out)
        if not changed:
            return command, None


def tokens_of(stage):
    """切成词，去掉前面的变量赋值、sudo/timeout 之类包装和 if/do 等关键字，以及输出重定向的目标。"""
    try:
        toks = shlex.split(stage, comments=False, posix=True)
    except ValueError:
        toks = stage.split()
    i = 0
    while i < len(toks):
        t = toks[i]
        if re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", t) or t in KEYWORDS:
            i += 1
        elif t in PREFIX_ARGS:
            i += 1
            while i < len(toks) and toks[i].startswith("-"):
                i += 2 if toks[i] in PREFIX_ARGS[t] else 1
            if t in ("timeout", "gtimeout") and i < len(toks):
                i += 1  # 时长
        else:
            break
    out, skip = [], False
    for t in toks[i:]:
        if skip:
            skip = False
            continue
        if re.match(r"^(\d|&)?>>?\|?$", t):
            skip = True
            continue
        if re.match(r"^(\d|&)?>", t):
            continue
        out.append(t)
    return out


def stdout_redirected(stage):
    """这一段的标准输出写进了文件（> f、>> f、&> f），不会出现在会话里。"""
    try:
        toks = shlex.split(stage, comments=False, posix=True)
    except ValueError:
        toks = stage.split()
    return any(re.match(r"^(1|&)?>>?\|?", t) and not t.startswith(("1>&2", ">&2")) for t in toks)


# ── 参数 ──────────────────────────────────────────────────────────────

def is_env_path(t):
    t = t[1:] if t.startswith("<") else t
    if not t or t.startswith(("-", "!", ":!", ":^", ":(")):
        return False
    base = t.split(":")[-1].rstrip("/").rsplit("/", 1)[-1]
    return bool(ENV_BASENAME.match(base)) and not TEMPLATE.search(base) and not CODE_EXT.search(base)


def env_files(args):
    out, skip = [], False
    for a in args:
        if skip:
            skip = False
            continue
        if a in GREP_ARG_FLAGS:
            skip = True
            continue
        if is_env_path(a):
            out.append(a[1:] if a.startswith("<") else a)
    return out


def short_flags(args):
    return "".join(a[1:] for a in args if re.match(r"^-[A-Za-z]+$", a))


def grep_split(args):
    """grep 参数拆成 (模式列表, 其余非选项参数)。没写 -e 时第一个非选项参数是模式。"""
    pats, rest, explicit, skip = [], [], False, None
    for a in args:
        if skip:
            if skip in ("-e", "--regexp"):
                pats.append(a)
                explicit = True
            skip = None
            continue
        if a in GREP_ARG_FLAGS:
            skip = a
        elif a.startswith("-e") and len(a) > 2 and not a.startswith("--"):
            pats.append(a[2:])
            explicit = True
        elif a.startswith("--regexp="):
            pats.append(a.split("=", 1)[1])
            explicit = True
        elif a.startswith("-"):
            continue
        else:
            rest.append(a)
    if not explicit and rest:
        pats.append(rest.pop(0))
    return pats, rest


def grep_flags(cmd, args):
    flags = short_flags(args)
    ctx = 0
    for i, a in enumerate(args):
        m = re.match(r"^-([ABC])(\d*)$", a) or re.match(r"^--(after-|before-)?context(?:=(\d+))?$", a)
        if m:
            n = m.group(2) or (args[i + 1] if i + 1 < len(args) else "0")
            ctx = max(ctx, int(n) if str(n).isdigit() else 0)
        elif re.match(r"^-\d+$", a):
            ctx = max(ctx, int(a[1:]))
    return {
        "invert": "v" in flags or "--invert-match" in args,
        "icase": "i" in flags or "--ignore-case" in args,
        "fixed": "F" in flags or cmd == "fgrep" or "--fixed-strings" in args,
        "ere": "E" in flags or "P" in flags or cmd in ("egrep", "rg", "ag"),
        "only": "o" in flags or "--only-matching" in args,
        "count": bool(re.search(r"[clLq]", flags)) or bool(
            {"--count", "--files-with-matches", "--files-without-match", "--quiet", "--silent"} & set(args)),
        "recursive": bool(re.search(r"[rR]", flags)) or "--recursive" in args or cmd in ("rg", "ag", "ack"),
        "hidden": "--hidden" in args or bool(re.search(r"u", flags)) or cmd != "rg",
        "context": ctx,
    }


# ── 过滤判断 ──────────────────────────────────────────────────────────

def key_only_filter(toks):
    """这一段的输出只有键名。"""
    if not toks:
        return False
    cmd, args = os.path.basename(toks[0]), toks[1:]
    joined = " ".join(args)
    if cmd == "git" and args[:1] == ["grep"]:
        cmd, args = "grep", args[1:]
    if cmd == "wc":
        return True
    if cmd == "cut":
        return bool(re.search(r"-d\s*=|--delimiter=?\s*=", joined)) and bool(
            re.search(r"(-f\s*1|--fields=?\s*1)(\s|$)", joined))
    if cmd == "sed":
        return any(re.match(r"^s(.)=\.\*\$?\1=?\1g?$", a) for a in args)
    if cmd in ("awk", "gawk", "mawk"):
        prog = [a for a in args if not a.startswith("-")]
        return bool(re.search(r"-F\s*['\"]?=", joined)) and bool(prog) and bool(
            re.match(r"^(/[^/]*/)?\s*\{\s*print\s+\$1\s*;?\s*\}$", prog[0]))
    if cmd not in GREPS:
        return False
    f = grep_flags(cmd, args)
    pats, _ = grep_split(args)
    if f["invert"] or f["context"]:
        return False
    if f["count"] and not f["only"]:
        return True
    return f["only"] and bool(pats) and all(
        p.startswith("^") and not re.search(r"[.]|\[\^|\\[SWs]|=.", p) for p in pats)


def exact_keys(pattern):
    """模式是以 ^ 开头的确切键（^KEY=、^(A|B)=、^P_(A|B)=，可带 diff 的 [-+] 和取值部分）时返回键名，否则 None。"""
    if not pattern.startswith("^"):
        return None
    p = re.sub(r"^\^(\[[-+]{2}\]|\\?[-+])?", "", pattern)
    m = re.match(r"^([A-Za-z0-9_]*)\\?\(([^()]*?)\\?\)(.*)$", p)
    alts = [m.group(1) + a + m.group(3) for a in re.split(r"\\?\|", m.group(2))] if m else re.split(r"\\?\|", p)
    keys = []
    for a in alts:
        a = re.sub(r"^\^?(\[[-+]{2}\]|\\?[-+])?", "", a)
        k = re.match(r"^([A-Za-z][A-Za-z0-9_]*[A-Za-z0-9])="
                     r"(\.[*+]|\\[Sw][*+]?|\[\^[^\]]*\][*+]?|\[\^\[:space:\]\][*+]?|\[[\w-]+\][*+]?|[\w.-]*)\$?$", a)
        if not k:
            return None
        keys.append(k.group(1))
    return keys


def named_keys_filter(toks):
    """拿不到内容时：grep 只点名了非敏感确切键，且不带上下文、不反选。"""
    if not toks:
        return False
    cmd, args = os.path.basename(toks[0]), toks[1:]
    if cmd == "git" and args[:1] == ["grep"]:
        cmd, args = "grep", args[1:]
    if cmd not in GREPS:
        return False
    f = grep_flags(cmd, args)
    pats, _ = grep_split(args)
    if f["invert"] or f["context"] or not pats:
        return False
    for p in pats:
        keys = exact_keys(p)
        if keys is None or any(SENSITIVE_KEY.search(k) or REMOTE_SENSITIVE_KEY.search(k) for k in keys):
            return False
    return True


def to_python_regex(p, f):
    if f["fixed"]:
        return re.escape(p)
    for k, v in POSIX_CLASSES.items():
        p = p.replace(k, v)
    if not f["ere"]:  # BRE：\| \( \) \+ \? 是元字符，裸的 | ( ) + ? 是字面量
        marks = {r"\|": "\0a", r"\(": "\0b", r"\)": "\0c", r"\+": "\0d", r"\?": "\0e"}
        for k, v in marks.items():
            p = p.replace(k, v)
        for ch in "|()+?":
            p = p.replace(ch, "\\" + ch)
        for k, v in marks.items():
            p = p.replace(v, k[1])
    return p


def sensitive_line(line):
    m = re.match(r"^[-+ ]?\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$", line)
    if not m:
        return False
    key, val = m.group(1), m.group(2).strip().strip("\"'")
    if not val:
        return False
    if SENSITIVE_KEY.search(key) or SENSITIVE_VALUE.search(val):
        return True
    random = len(val) >= 24 and re.fullmatch(r"[A-Za-z0-9+/=_-]+", val) and re.search(r"\d", val) and re.search(
        r"[A-Za-z]", val)
    return bool(random) and not re.search(r"_(ID|IDS|UUID)$", key, re.I)


def select_lines(lines, sel_toks):
    """按 grep（含上下文）或 sed -n 行号算出会被打印的行；算不了返回 None。"""
    cmd, args = os.path.basename(sel_toks[0]), sel_toks[1:]
    if cmd == "git" and args[:1] == ["grep"]:
        cmd, args = "grep", args[1:]
    if cmd == "sed":
        script = [a for a in args if not a.startswith("-")]
        m = re.match(r"^(\d+)(?:,(\d+))?p$", script[0]) if "-n" in args and script else None
        if not m:
            return None
        lo, hi = int(m.group(1)), int(m.group(2) or m.group(1))
        return lines[lo - 1:hi]
    if cmd not in GREPS:
        return None
    f = grep_flags(cmd, args)
    pats, _ = grep_split(args)
    if not pats:
        return None
    try:
        regs = [re.compile(to_python_regex(p, f), re.I if f["icase"] else 0) for p in pats]
    except re.error:
        return None
    hit = [i for i, ln in enumerate(lines) if any(r.search(ln) for r in regs) != f["invert"]]
    keep = set()
    for i in hit:
        keep.update(range(max(0, i - f["context"]), min(len(lines), i + f["context"] + 1)))
    return [lines[i] for i in sorted(keep)]


def read_local(files, cwd):
    """读本机 env 文件的全部行；有文件找不到或不是普通文件时返回 None。"""
    lines = []
    for name in files:
        path = os.path.expanduser(name if os.path.isabs(os.path.expanduser(name)) else os.path.join(cwd, name))
        found = glob.glob(path) if "*" in path else [path]
        if not found:
            return None
        for p in found:
            if TEMPLATE.search(p) or CODE_EXT.search(p):
                continue
            if not os.path.isfile(p):
                return None
            with open(p, encoding="utf-8", errors="replace") as fh:
                lines.extend(fh.read().splitlines())
    return lines


def git(cwd, *args):
    try:
        r = subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True, timeout=3)
    except (OSError, subprocess.SubprocessError):
        return None
    return r.stdout if r.returncode == 0 else None


def git_env_paths(cwd, rev=None):
    out = git(cwd, "ls-tree", "-r", "--name-only", rev) if rev else git(cwd, "ls-files")
    if out is None:
        return None
    return [p for p in out.splitlines() if is_env_path(p)]


def walk_env_files(dirs, cwd, f, include, exclude):
    """grep -r 会扫到的 env 文件（跳过 .git、node_modules 等；rg 不加 --hidden 时跳过隐藏文件）。
    文件数超过 5 万时返回 None：没扫完，不能说里面没有 env 文件。"""
    found, seen = [], 0
    for d in dirs:
        root = os.path.expanduser(d if os.path.isabs(os.path.expanduser(d)) else os.path.join(cwd, d))
        if os.path.isfile(root):
            continue
        for dp, dns, fns in os.walk(root):
            dns[:] = [n for n in dns if n not in SKIP_DIRS and (f["hidden"] or not n.startswith("."))]
            for n in fns:
                seen += 1
                if is_env_path(n) and (f["hidden"] or not n.startswith(".")) \
                        and (not include or any(fnmatch.fnmatch(n, g) for g in include)) \
                        and not any(fnmatch.fnmatch(n, g) for g in exclude):
                    found.append(os.path.join(dp, n))
            if seen > 50000:
                return None
    return found


# ── 哪一段在输出 env 内容 ──────────────────────────────────────────────

def emits(toks, cwd):
    """这一段会把 env / environ / cookie 内容输出时返回 dict(reason, kind, lines)；lines 是拿得到时的全部内容。"""
    if not toks:
        return None
    cmd, args = os.path.basename(toks[0]), toks[1:]
    operands = grep_split(args)[1] if cmd in GREPS else args  # grep 的模式里写着 environ 路径不算
    if any(PROC_ENVIRON.search(t) for t in operands) and (cmd in ENVIRON_READERS or "<" in toks or any(
            t.startswith("<") and PROC_ENVIRON.search(t) for t in toks)):
        return {"reason": "读 /proc/<pid>/environ 会打印进程的全部环境变量（含口令）", "kind": "proc"}
    if "cookies" in toks:
        nxt = toks[toks.index("cookies") + 1] if toks.index("cookies") + 1 < len(toks) else ""
        if (cmd == "agent-browser" and nxt not in ("set", "clear", "delete", "--help", "-h")) or nxt == "get":
            return {"reason": "cookies（get）会打印会话 token", "kind": "cookie"}
    if cmd == "git":
        return emits_git(args, cwd)
    if cmd in GREPS:
        f = grep_flags(cmd, args)
        _, rest = grep_split(args)
        files = env_files(rest)
        if f["recursive"] and cwd:
            dirs = [r for r in rest if os.path.isdir(os.path.join(cwd, os.path.expanduser(r)))] if rest else ["."]
            include = [a.split("=", 1)[1] for a in args if a.startswith("--include=")]
            exclude = [a.split("=", 1)[1] for a in args if a.startswith("--exclude=")]
            walked = walk_env_files(dirs, cwd, f, include, exclude) if dirs else []
            if walked is None:
                return {"reason": "%s -r 扫的目录太大（超过 5 万个文件），hook 没法确认里面有没有 env 文件" % cmd,
                        "kind": "grep"}
            files += walked
        if not files:
            return None
        return {"reason": "%s 会把 env 文件里的值打印出来" % cmd, "kind": "grep",
                "lines": read_local(files, cwd) if cwd else None}
    files = env_files(args)
    if not files:
        return None
    lines = read_local(files, cwd) if cwd else None
    if cmd in ("source", "."):
        return {"reason": "source 会执行 env 文件，含 & * 的口令行报错时会把口令片段打进会话", "kind": "source"}
    if cmd == "sed":
        if re.search(r"(^|\s)-i", " ".join(args)):
            return None
        return {"reason": "sed 会打印 env 文件内容", "kind": "sed", "lines": lines}
    if cmd in ("cut", "awk", "gawk", "mawk"):
        return {"reason": "%s 会打印 env 文件里的值" % cmd, "kind": "print"}
    if cmd in PRINTERS:
        return {"reason": "%s 会打印 env 文件内容" % cmd, "kind": "whole" if cmd in WHOLE_FILE else "print",
                "lines": lines}
    if cmd in NON_PRINTING:
        return None
    redirected = any(t == "<" and j + 1 < len(toks) and is_env_path(toks[j + 1]) for j, t in enumerate(toks)) or any(
        t.startswith("<") and len(t) > 1 and is_env_path(t[1:]) for t in toks)
    if redirected:
        return {"reason": "%s 从 env 文件读输入，会把内容打印出来" % cmd, "kind": "whole", "lines": lines}
    return None


def emits_git(args, cwd):
    i = 0
    while i < len(args) and args[i].startswith("-"):
        i += 2 if args[i] in ("-c", "-C") else 1
    if i >= len(args):
        return None
    sub, rest = args[i], args[i + 1:]
    if STAT_FLAGS & set(rest) and sub != "grep":
        return None
    if "--" in rest:
        revs, paths = rest[:rest.index("--")], rest[rest.index("--") + 1:]
    else:
        revs, paths = rest, []
    revs = [r for r in revs if not r.startswith("-")]
    env_in_args = [p for p in paths + revs if is_env_path(p)]

    if sub == "grep":
        strict = {"reason": "git grep 会把 env 文件里的值打印出来", "kind": "grep"}
        before = rest[:rest.index("--")] if "--" in rest else rest
        _, others = grep_split(before)
        if paths and not any(is_env_path(p) for p in paths):
            return None
        if not cwd:
            return strict if env_in_args else None
        rev = next((r for r in others if not is_env_path(r)
                    and git(cwd, "rev-parse", "--verify", "-q", r + "^{object}") is not None), None)
        targets = [p for p in paths + others if is_env_path(p)] or git_env_paths(cwd, rev)
        if targets is None:
            return strict
        if not targets:
            return None
        lines = []
        for p in targets:
            if rev:
                text = git(cwd, "show", "%s:./%s" % (rev, p))
                got = None if text is None else text.splitlines()
            else:
                got = read_local([p], cwd)
            if got is None:
                return strict
            lines.extend(got)
        return dict(strict, lines=lines)

    if sub in ("show", "cat-file", "blame"):
        blob = [r for r in revs if ":" in r and is_env_path(r)]
        if blob and sub == "show":  # git show <rev>:<path>：整份文件，能拿到内容
            text = git(cwd, "show", blob[0]) if cwd else None
            return {"reason": "git show 会打印 env 文件内容", "kind": "whole",
                    "lines": text.splitlines() if text is not None else None}
        if sub == "show" and cwd:  # 先问 git 这次会显示哪些文件；问不出来时按涉及 env 处理
            names = git(cwd, "show", "--name-only", "--format=", *revs, *(["--", *paths] if paths else []))
            if names is None and env_in_args or names is not None and any(is_env_path(n) for n in names.splitlines()):
                return {"reason": "git show 这个提交改了 env 文件，会打印口令的改动", "kind": "patch"}
            return None
        if env_in_args:
            return {"reason": "git %s 会打印 env 文件内容" % sub, "kind": "patch"}
        return None
    if sub == "diff":
        if cwd:
            names = git(cwd, "diff", "--name-only", *revs, *(["--", *paths] if paths else []))
            if names is None and env_in_args or names is not None and any(is_env_path(n) for n in names.splitlines()):
                return {"reason": "git diff 涉及 env 文件，会打印口令的改动", "kind": "patch"}
            return None
        return {"reason": "git diff 会打印 env 文件的改动内容", "kind": "patch"} if env_in_args else None
    if sub == "log" and ({"-p", "-u", "--patch"} & set(rest) or "p" in short_flags(rest)):
        if env_in_args:
            return {"reason": "git log -p 会打印 env 文件的改动内容", "kind": "patch"}
        if cwd and not paths:  # 不限提交数，靠 3 秒超时；超时按涉及 env 处理
            names = git(cwd, "log", "--name-only", "--format=",
                        *[r for r in rest if r not in ("-p", "-u", "--patch") and not re.match(r"^-[A-Za-z]*p", r)])
            if names is None or any(is_env_path(n) for n in names.splitlines()):
                return {"reason": "git log -p 会打印 env 文件的改动内容", "kind": "patch"}
        return None
    return None


def environ_filter_ok(toks):
    """environ 的下游：只看键名、点名非敏感键，或 grep -o 一个不含敏感词的片段（例如主机）。"""
    if key_only_filter(toks) or named_keys_filter(toks):
        return True
    if toks and os.path.basename(toks[0]) in GREPS and grep_flags(toks[0], toks[1:])["only"]:
        return not any(SENSITIVE_TEXT.search(p) for p in grep_split(toks[1:])[0])
    return False


def analyze(command, cwd=None, depth=0):
    if depth > 3:
        return None
    command, bodies = split_heredocs(command)
    for prefix, body in bodies:  # 喂给 bash/ssh 的 heredoc 正文是命令
        segs = split_unquoted(prefix, ["&&", "||", ";", "|"])
        toks = tokens_of(segs[-1]) if segs else []
        cmd = os.path.basename(toks[0]) if toks else ""
        if cmd in SHELLS or cmd == "ssh":
            reason = analyze(body, None if cmd == "ssh" else cwd, depth + 1)
            if reason:
                return reason
    command, reason = resolve_substitutions(command, cwd, depth)
    if reason:
        return reason
    for stmt in split_unquoted(command, ["&&", "||", ";", "\n"]):
        stage_texts = split_unquoted(stmt, ["|&", "|"])
        stages = [tokens_of(s) for s in stage_texts]
        if stages and stages[0][:1] == ["cd"] and cwd:
            target = stages[0][1] if len(stages[0]) > 1 else "~"
            cwd = os.path.normpath(os.path.join(cwd, os.path.expanduser(target)))
            continue
        for i, toks in enumerate(stages):
            if not toks:
                continue
            reason = nested(toks, stages[i - 1] if i else None, cwd, depth)
            if reason:
                return reason
            hit = emits(toks, cwd)
            if not hit:
                continue
            later = stages[i + 1:]
            where = "（被拦的一段：%s）" % stage_texts[i][:120]
            kind = hit["kind"]
            if kind == "source":
                return hit["reason"] + where
            if kind == "proc":
                if environ_filter_ok(toks) or any(environ_filter_ok(t) for t in later):
                    continue
                return hit["reason"] + "；只接 | cut -d= -f1 看键名，或 grep -o 只取库名、主机这类非敏感字段" + where
            if kind == "cookie":
                text = " ".join(" ".join(t) for t in later)
                if later and "name" in text and "value" not in text:
                    continue
                return hit["reason"] + "；只解析出 cookie 名字（例如 | jq -r '.[].name'），注入用 JSON 文件" + where
            if stdout_redirected(stage_texts[-1]):
                continue
            if key_only_filter(toks) or any(key_only_filter(t) for t in later):
                continue
            lines = hit.get("lines")
            if lines is not None and kind in ("grep", "whole", "sed"):
                sel = toks if kind in ("grep", "sed") else next(
                    (t for t in later if t and os.path.basename(t[0]) in GREPS), None)
                picked = select_lines(lines, sel) if sel else None
                if picked is None and kind == "whole" and not sel:
                    picked = lines
                if picked is not None:
                    if any(sensitive_line(ln) for ln in picked):
                        return hit["reason"] + "，会打印出的行里有口令类的值" + where
                    continue
            if named_keys_filter(toks) or any(named_keys_filter(t) for t in later):
                continue
            return hit["reason"] + where
    return None


def unescape_dq(s):
    """shlex 在双引号里保留 \\$ 和 \\`，bash 会去掉反斜杠；传给下一层的命令串里 $(...) 是会执行的。"""
    return s.replace("\\$", "$").replace("\\`", "`")


def nested(toks, prev_toks, cwd, depth):
    """ssh / bash -c / eval / echo … | bash 里的命令串。"""
    cmd, args = os.path.basename(toks[0]), toks[1:]
    if cmd == "ssh":
        i = 0
        while i < len(args) and args[i].startswith("-") and len(args[i]) > 1:
            i += 1 if (args[i][1] not in SSH_OPT_ARG or len(args[i]) > 2) else 2
        rest = args[i + 1:]
        remote = " ".join(rest[1:] if rest[:1] == ["--"] else rest)
        remote = unescape_dq(remote)
        reason = analyze(remote, None, depth + 1) if remote else None
        if reason:
            return reason
        rt = tokens_of(remote) if remote else []
        if (not rt or os.path.basename(rt[0]) in SHELLS) and prev_toks and os.path.basename(prev_toks[0]) in (
                "echo", "printf"):
            return analyze(" ".join(prev_toks[1:]), None, depth + 1)
        return None
    if cmd in SHELLS:
        for a in args:
            if re.search(r"[\s|;&<>]", a):
                reason = analyze(unescape_dq(a), cwd, depth + 1)
                if reason:
                    return reason
        if not any(re.search(r"[\s|;&<>]", a) for a in args) and prev_toks and os.path.basename(prev_toks[0]) in (
                "echo", "printf"):
            return analyze(" ".join(prev_toks[1:]), cwd, depth + 1)
        return None
    if cmd == "eval":
        return analyze(unescape_dq(" ".join(args)), cwd, depth + 1)
    return None


def main():
    try:
        data = json.load(sys.stdin)
    except (ValueError, OSError):
        return 0
    tool = data.get("tool_name")
    ti = data.get("tool_input") or {}
    reason = None
    try:
        if tool == "Read":
            path = ti.get("file_path") or ""
            if is_env_path(os.path.basename(path) or path):
                reason = "Read 会把 env 文件全文（含口令）读进会话"
        elif tool == "Bash":
            reason = analyze(ti.get("command") or "", data.get("cwd") or os.getcwd())
    except Exception:  # 解析器自身出错时放行，和其他 hook 一致
        return 0
    if not reason:
        return 0
    sys.stderr.write("secret-print-guard: %s。%s\n" % (reason, HOWTO))
    return 2


if __name__ == "__main__":
    sys.exit(main())
