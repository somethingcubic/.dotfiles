#!/usr/bin/env zsh
# ~/.claude/hooks/check-lazy.sh
# Trigger: PostToolUse (Write, Edit)
# Detects lazy patterns in written code files. Warning mode (exit 0), non-blocking.

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

[[ -z "$FILE_PATH" ]] && exit 0
[[ ! -f "$FILE_PATH" ]] && exit 0

# Whitelist: only check code files
case "$FILE_PATH" in
  *.go|*.py|*.js|*.ts|*.tsx|*.jsx|*.java|*.rs|*.sh|*.rb|*.php|*.c|*.cpp|*.h|*.swift|*.kt) ;;
  *) exit 0 ;;
esac

LAZY_PATTERNS='TODO|FIXME|XXX|HACK|implement this|placeholder|not implemented'
MATCHES=$(grep -nE "$LAZY_PATTERNS" "$FILE_PATH" 2>/dev/null)

if [[ -n "$MATCHES" ]]; then
  echo "⚠️ LAZY PATTERN DETECTED in $FILE_PATH:"
  echo "$MATCHES"
  echo ""
  echo "如果这是已有的 TODO（非本次新增），请继续。否则请要求 agent 补全实现。"
fi

exit 0
