#!/usr/bin/env python3
"""chinese-reply-gate.py — Stop: 本轮回复（含工具调用之间的进度短句）出现英文段落时拦下，要求用中文重述。

只看最后一个轮次起点（用户输入、hook 反馈、定时唤醒）之后、assistant 的 text 块（不看 thinking 和工具输入）。
最后一段回复以 stdin 的 last_assistant_message 为准：hook 启动时记录文件常常还没写入这一段
（2026-10-19 实测 7 次 Stop 里 6 次，hook 启动后 0.1 秒内才写入），只读记录文件会漏拦。
先去掉代码块、行内代码、URL 和路径，再按「拉丁字母数 vs 汉字数」判断。
stop_hook_active 为真时放行，避免反复拦截。用户明确要求英文时由用户自行关掉。
起因：2026-10-12 同一 session 两次用英文回复（lessons.md「通用」）。
"""
import json
import re
import sys

MIN_LATIN = 40      # 去掉代码等之后，拉丁字母少于这个数的块不判
MAX_CJK_RATIO = 0.2  # 汉字 / (汉字 + 拉丁字母) 低于这个比例算英文段落

STRIP = [
    re.compile(r"```.*?```", re.S),
    re.compile(r"`[^`\n]*`"),
    re.compile(r"https?://\S+"),
    re.compile(r"(?:~|\.{0,2})?/[\w./@-]+"),
]
CJK = re.compile(r"[一-鿿]")
LATIN = re.compile(r"[A-Za-z]")


def is_english(text):
    for p in STRIP:
        text = p.sub(" ", text)
    latin, cjk = len(LATIN.findall(text)), len(CJK.findall(text))
    return latin >= MIN_LATIN and cjk / (cjk + latin) < MAX_CJK_RATIO


def is_turn_start(entry):
    # 用户输入、Stop hook 反馈、定时唤醒（后两者是 isMeta 的字符串）都算新一轮起点；只有工具结果不算。
    # 否则上一轮已被纠正的英文会在下一轮被反复拦截。
    if entry.get("type") != "user" or entry.get("isSidechain"):
        return False
    content = entry.get("message", {}).get("content")
    if isinstance(content, str):
        return True
    if isinstance(content, list):
        return not any(isinstance(b, dict) and b.get("type") == "tool_result" for b in content)
    return False


def turn_texts(path):
    entries = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            try:
                entries.append(json.loads(line))
            except ValueError:
                continue
    start = 0
    for i, e in enumerate(entries):
        if is_turn_start(e):
            start = i + 1
    texts = []
    for e in entries[start:]:
        if e.get("type") != "assistant" or e.get("isSidechain"):
            continue
        for b in e.get("message", {}).get("content") or []:
            if isinstance(b, dict) and b.get("type") == "text" and b.get("text", "").strip():
                texts.append(b["text"])
    return texts


def main():
    try:
        data = json.load(sys.stdin)
    except ValueError:
        return 0
    if data.get("stop_hook_active"):
        return 0
    texts = []
    path = data.get("transcript_path")
    if path:
        try:
            texts = turn_texts(path)
        except OSError:
            pass
    last = (data.get("last_assistant_message") or "").strip()
    if last and last not in (t.strip() for t in texts):
        texts.append(last)
    bad = [t for t in texts if is_english(t)]
    if not bad:
        return 0
    sample = bad[0].strip().replace("\n", " ")[:120]
    print(json.dumps({
        "decision": "block",
        "reason": f"chinese-reply-gate：本轮有 {len(bad)} 段对用户可见的文字是英文（例：「{sample}」）。"
                  "回复一律用中文，工具调用之间的进度短句也一样。用中文简短重述这些内容的要点，不要重复已经用中文说过的部分。",
    }, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
