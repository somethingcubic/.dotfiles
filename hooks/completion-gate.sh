#!/usr/bin/env zsh
# ~/.claude/hooks/completion-gate.sh
# Trigger: Stop
# Warns about uncommitted changes at session end. Advisory only.

git rev-parse --is-inside-work-tree &>/dev/null || exit 0

UNCOMMITTED=$(git diff --name-only 2>/dev/null)
UNTRACKED=$(git ls-files --others --exclude-standard 2>/dev/null)

if [[ -n "$UNCOMMITTED" || -n "$UNTRACKED" ]]; then
  echo "⚠️ 会话结束前有未提交的变更："
  [[ -n "$UNCOMMITTED" ]] && echo "Modified: $UNCOMMITTED"
  [[ -n "$UNTRACKED" ]] && echo "Untracked: $UNTRACKED"
  echo "确认这些变更已经过 review。"
fi

exit 0
