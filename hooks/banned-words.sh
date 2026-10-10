#!/bin/bash
# banned-words.sh — PostToolUse(Edit|Write|MultiEdit): 扫描写入的文档文件（.md/.txt/.html）中的禁用词，命中时通过 stderr 提示 agent 改写。
# 不阻断写入；代码文件不扫描。词表与 AGENTS.md「禁用词」一节保持一致。

file=$(jq -r '.tool_input.file_path // empty')
case "$file" in
  *.md|*.txt|*.html|*.htm) ;;
  *) exit 0 ;;
esac
[ -f "$file" ] || exit 0

# 本词表文件自身和规则文件不扫描
case "$file" in
  */agents/AGENTS.md|*/.claude/CLAUDE.md|*/rules/*|*/postmortems/*) exit 0 ;;
esac

pattern='Prevent|Guarantee|Will never|Fixes|Eliminates|Ensures that|seamless|leverage|robust solution|赋能|抓手|闭环|底层逻辑|颗粒度|拉齐|打法|心智|一站式|无缝|全方位|毋庸置疑|值得注意的是|本质上|综上所述|总的来说'

hits=$(grep -nE "$pattern" "$file" | head -20)
[ -z "$hits" ] && exit 0

{
  echo "banned-words: $file 含禁用词（引用原文除外）。请改写以下行："
  echo "$hits"
} >&2
exit 2
