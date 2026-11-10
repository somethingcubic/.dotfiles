#!/usr/bin/env python3
"""zsh-word-split-guard.py — PreToolUse(Bash)：拦下「多个参数放进一个变量，再不加引号展开当命令参数」的写法。

起因：Bash 工具跑的是 zsh，不加引号的 $VAR 不按空格拆分。O="-o ConnectTimeout=10 -o ServerAliveInterval=5"; ssh $O host
会把整串当成一个参数，ssh 报 keyword connecttimeout extra arguments at end of line。lessons 2026-10-27 已有这条规则，
2026-11-10 再犯：一个后台监控脚本每次连接都失败，一条数据都没采到。改成 hook。

判据（同一条命令里，按出现顺序）：
  1. 先有赋值 NAME="…" / NAME='…'，值里有空格（引号里或 \\ 转义的空格，$(…) 里的不算），可带 export/local/typeset 等前缀。
     只给一条命令的前缀赋值（NAME=… cmd）不算；之后又赋成不含空格的值或数组 NAME=(…)，就不再算。
     值是一个带空格的路径（以 /、~/、$HOME/ 这类开头，空格后面不再出现 -、/、~）不算，zsh 里不加引号也能用。
  2. 后面有不加引号的 $NAME 或 ${NAME}，出现在命令名、命令参数或 for … in 的列表里。
不算命令参数的位置：引号里（"$NAME"、bash -c '…'）、heredoc 正文（含写进 #!/bin/bash 脚本文件的内容）、赋值右边、
重定向目标、[[ ]] / [ ] / test、echo / print / eval 的参数、bash/sh/zsh -c 后面那一个参数、ssh 主机名之后的远程命令部分。
${=NAME}、$=NAME、${NAME[@]} 等其他展开形式不算。解析器自身出错时放行，和其他 hook 一致。
已知不拦：值来自命令替换（NAME=$(…)）、变量在之前的 Bash 调用里赋值、zsh -c 里面的写法。
用例见 hooks/tests/zsh-word-split-guard.test.sh。
"""
import json
import os
import re
import sys

NAME = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
ASSIGN = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)(\+?)=")
REDIR = re.compile(r"<<<|<<-|<<|<>|<&|>&|>>|>\||>!|>|<")
FD_REDIR = re.compile(r"\d+(?=[<>])")
SUB = "\x00"  # 字面文本里代替 $NAME、$(…) 等展开的占位符
RESERVED = {"if", "then", "else", "elif", "fi", "do", "done", "while", "until", "{", "}", "!", "esac", "time"}
DECL = {"export", "local", "typeset", "declare", "readonly", "integer", "float", "private"}
NO_SPLIT_CMDS = {"echo", "print", "eval", "[", "test", "[[", "case"}
WRAPPERS = {"nohup", "command", "exec", "builtin", "noglob", "nocorrect", "nice", "sudo", "caffeinate"}
SHELLS = {"bash", "sh", "zsh", "dash", "ksh"}
SSH_ARG_OPTS = set("BbcDEeFIiJLlmOoPpQRSWw")

RULE = ("规则（lessons 2026-10-27）：Bash 工具跑的是 zsh：不加引号的 `$VAR` 不按空格拆分，`set -- $st`、`cmd $OPTS` "
        "都会把整串当一个参数；拆字段用 python/`read`，传多个参数用数组或环境变量，脚本要按 bash 语义写时用 `bash -c`。")
HOWTO = ("改法任选一种：① 参数直接写在命令里：ssh -o ConnectTimeout=10 -o ServerAliveInterval=5 host；"
         "② 用数组：O=(-o ConnectTimeout=10 -o ServerAliveInterval=5); ssh \"${O[@]}\" host；"
         "③ 整段放进 bash -c '…'。本来就只想传一个参数时，加引号写成 \"$NAME\"。")


class Word:
    __slots__ = ("text", "lit", "refs", "nested", "space", "array")

    def __init__(self):
        self.text = ""      # 原文
        self.lit = []       # 去掉引号后的字面字符，展开处放 SUB
        self.refs = []      # 不加引号的 $NAME / ${NAME}
        self.nested = []    # $(…)、`…`、<(…) 里的命令（各是一份 token 列表）
        self.space = False  # 字面文本里有空格（引号里或转义的）
        self.array = False  # NAME=(…)


def match_paren(s, i):
    """s[i] == '('，返回配对的 ')' 之后的位置；跳过引号。"""
    depth, n = 0, len(s)
    while i < n:
        c = s[i]
        if c == "\\":
            i += 2
            continue
        if c == "'":
            j = s.find("'", i + 1)
            i = n if j < 0 else j + 1
            continue
        if c == '"':
            i = skip_dq(s, i + 1)
            continue
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return n


def skip_dq(s, i):
    n = len(s)
    while i < n:
        if s[i] == "\\":
            i += 2
        elif s[i] == '"':
            return i + 1
        else:
            i += 1
    return n


def match_brace(s, i):
    """i 在 '${' 的 '{' 之后，返回配对的 '}' 之后的位置。"""
    depth, n = 1, len(s)
    while i < n:
        c = s[i]
        if c == "\\":
            i += 2
            continue
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return n


def lex_dollar(s, i, w, quoted):
    n = len(s)
    nx = s[i + 1:i + 2]
    w.lit.append(SUB)
    if s.startswith("$((", i):
        return match_paren(s, i + 1)
    if nx == "(":
        sub, j = lex(s, i + 2, ")")
        w.nested.append(sub)
        return j
    if nx == "{":
        j = match_brace(s, i + 2)
        if not quoted and NAME.fullmatch(s[i + 2:j - 1]):
            w.refs.append(s[i + 2:j - 1])
        return j
    if nx == "'":  # $'…'
        j = i + 2
        while j < n and s[j] != "'":
            j += 2 if s[j] == "\\" else 1
        return j + 1
    m = NAME.match(s, i + 1)
    if m:
        if not quoted and s[m.end():m.end() + 1] != "[":
            w.refs.append(m.group())
        return m.end()
    return i + 1  # $?、$#、$1、$= 之类


def lex_dq(s, i, w):
    n = len(s)
    while i < n:
        c = s[i]
        if c == '"':
            return i + 1
        if c == "\\" and i + 1 < n:
            w.lit.append(s[i + 1])
            i += 2
        elif c == "`":
            sub, i = lex(s, i + 1, "`")
            w.nested.append(sub)
            w.lit.append(SUB)
        elif c == "$":
            i = lex_dollar(s, i, w, True)
        else:
            if c in " \t\n":
                w.space = True
            w.lit.append(c)
            i += 1
    return n


def lex_word(s, i):
    w, start, n = Word(), i, len(s)
    while i < n:
        c = s[i]
        if c in " \t\n;&|)":
            break
        if c == "(":
            if ASSIGN.fullmatch(s[start:i]):
                w.array = True
            i = match_paren(s, i)  # 数组赋值或 zsh glob 限定符
            continue
        if c in "<>":
            if s[i + 1:i + 2] == "(" and i == start:  # 进程替换
                sub, i = lex(s, i + 2, ")")
                w.nested.append(sub)
                w.lit.append(SUB)
                continue
            break
        if c == "\\":
            if i + 1 < n:
                if s[i + 1] in " \t":
                    w.space = True
                w.lit.append(s[i + 1])
            i += 2
        elif c == "'":
            j = s.find("'", i + 1)
            j = n if j < 0 else j
            body = s[i + 1:j]
            if re.search(r"[ \t\n]", body):
                w.space = True
            w.lit.append(body)
            i = j + 1
        elif c == '"':
            i = lex_dq(s, i + 1, w)
        elif c == "`":
            sub, i = lex(s, i + 1, "`")
            w.nested.append(sub)
            w.lit.append(SUB)
        elif c == "$":
            i = lex_dollar(s, i, w, False)
        else:
            w.lit.append(c)
            i += 1
    w.text = s[start:i]
    w.lit = "".join(w.lit)
    return w, i


def skip_heredocs(s, i, pending):
    n = len(s)
    for delim, dash in pending:
        while i < n:
            e = s.find("\n", i)
            e = n if e < 0 else e
            line = s[i:e]
            i = e + 1
            if (line.lstrip("\t") if dash else line) == delim:
                break
    return i


def lex(s, i, stop):
    """返回 (tokens, 结束位置)。token：("w", Word) / ("op", str) / ("redir", str)。stop：None、")"、"`"。"""
    toks, pending, heredoc_next, depth, n = [], [], None, 0, len(s)
    while i < n:
        c = s[i]
        if c == "\n":
            toks.append(("op", "\n"))
            i += 1
            if pending:
                i = skip_heredocs(s, i, pending)
                pending = []
            continue
        if c in " \t":
            i += 1
            continue
        if c == "\\" and s[i + 1:i + 2] == "\n":
            i += 2
            continue
        if c == "#":
            e = s.find("\n", i)
            i = n if e < 0 else e
            continue
        if stop == "`" and c == "`":
            return toks, i + 1
        if c == ")":
            if stop == ")" and depth == 0:
                return toks, i + 1
            depth = max(0, depth - 1)
            toks.append(("op", ")"))
            i += 1
            continue
        if c == "(":
            depth += 1
            toks.append(("op", "("))
            i += 1
            continue
        if c == "&" and s[i + 1:i + 2] == ">":
            i += 3 if s.startswith("&>>", i) else 2
            toks.append(("redir", "&>"))
            continue
        if c in ";&|":
            op = s[i:i + 2] if s[i:i + 2] in (";;", ";&", ";|", "&&", "||", "|&") else c
            toks.append(("op", op))
            i += len(op)
            continue
        m = FD_REDIR.match(s, i)
        if m:
            i = m.end()
            c = s[i]
        if c in "<>" and s[i + 1:i + 2] != "(":
            op = REDIR.match(s, i).group()
            toks.append(("redir", op))
            i += len(op)
            if op in ("<<", "<<-"):
                heredoc_next = op
            continue
        w, i = lex_word(s, i)
        toks.append(("w", w))
        if heredoc_next:
            pending.append((re.sub(r"[\"'\\]", "", w.text), heredoc_next == "<<-"))
            heredoc_next = None
    return toks, i


def spaced_value(w):
    """赋值词的值是否算「多个参数」。"""
    if w.array or not w.space:
        return False
    val = w.lit.split("=", 1)[1]
    if re.match(r"(?:[~/]|\x00/)", val) and not re.search(r"\s[-/~]", val):
        return False  # 一个带空格的路径
    return True


def apply_assign(w, state):
    m = ASSIGN.match(w.text)
    name, append = m.group(1), m.group(2)
    spaced = spaced_value(w)
    state[name] = (state.get(name, False) or spaced) if append else spaced


def first_hit(words, state):
    for w in words:
        for r in w.refs:
            if state.get(r):
                return r, w
    return None


def check_simple(words, state):
    i = 0
    while i < len(words) and words[i].text in RESERVED:
        i += 1
    if i >= len(words):
        return None
    first = words[i].text
    if first in ("for", "select"):
        texts = [w.text for w in words]
        if "in" in texts[i:]:
            k = texts.index("in", i)
            return first_hit([w for w in words[k + 1:] if w.text != "do"], state)
        return None
    while i < len(words) and ASSIGN.match(words[i].text):
        i += 1
    if i >= len(words):
        for w in words:
            if ASSIGN.match(w.text):
                apply_assign(w, state)
        return None
    rest = words[i:]
    # 找真正的命令名：跳过 nohup / sudo / timeout 5 这类包装
    k = 0
    while k < len(rest):
        name = os.path.basename(rest[k].lit)
        if name in WRAPPERS:
            k += 1
        elif name in ("timeout", "gtimeout"):
            k += 1
            while k < len(rest) and rest[k].lit.startswith("-"):
                k += 1
            k += 1
        else:
            break
    if k >= len(rest):
        return first_hit(rest, state)
    cmd = os.path.basename(rest[k].lit)
    args = rest[k + 1:]
    if cmd in DECL:
        for w in args:
            if ASSIGN.match(w.text):
                apply_assign(w, state)
        return None
    if cmd in NO_SPLIT_CMDS:
        return None
    checked = rest[:k + 1]
    if cmd in SHELLS:
        for j, w in enumerate(args):
            if re.fullmatch(r"-[A-Za-z]*c[A-Za-z]*", w.lit):
                args = args[:j + 1] + args[j + 2:]  # -c 后面那一个参数由 shell 自己解析
                break
    elif cmd == "ssh":
        j = 0
        while j < len(args):
            a = args[j].lit
            if a == "--":
                j += 1
                break
            if a.startswith("-") and len(a) > 1:
                for p, ch in enumerate(a[1:]):
                    if ch in SSH_ARG_OPTS:
                        if p == len(a) - 2:
                            j += 1
                        break
                j += 1
                continue
            break
        args = args[:j + 1]  # 主机名之后是远程命令，ssh 会用空格拼起来
    return first_hit(checked + args, state)


def analyze(toks, state):
    cmd, redir_target = [], False
    for kind, val in toks + [("op", ";")]:
        if kind == "redir":
            redir_target = True
            continue
        if kind == "w":
            for sub in val.nested:
                hit = analyze(sub, state)
                if hit:
                    return hit
            if redir_target:
                redir_target = False
            else:
                cmd.append(val)
            continue
        hit = check_simple(cmd, state)
        if hit:
            return hit
        cmd, redir_target = [], False
    return None


def find_hit(command):
    toks, _ = lex(command, 0, None)
    return analyze(toks, {})


def main():
    try:
        data = json.load(sys.stdin)
    except (ValueError, OSError):
        return 0
    if data.get("tool_name") != "Bash":
        return 0
    try:
        hit = find_hit((data.get("tool_input") or {}).get("command") or "")
    except Exception:  # 解析器自身出错时放行，和其他 hook 一致
        return 0
    if not hit:
        return 0
    name, word = hit
    sys.stderr.write(
        "zsh-word-split-guard: 变量 %s 的值含空格，后面不加引号展开成 %s 当命令参数；zsh 不按空格拆分，"
        "整串会作为一个参数传给命令（ssh 会报 keyword … extra arguments at end of line）。%s%s\n"
        % (name, word.text, RULE, HOWTO))
    return 2


if __name__ == "__main__":
    sys.exit(main())
