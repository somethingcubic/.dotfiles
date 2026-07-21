#!/bin/zsh
# Block direct commits/merges/pushes to main + wholesale git -C / --git-dir / --work-tree ban.
# Reads PreToolUse Bash hook stdin JSON.
# NOTE: never pipe via `echo` — zsh builtin echo interprets backslashes and corrupts
# JSON/commands containing \" (fail-open class found 2026-07-21). Use printf '%s\n'.
# 2026-03-31 incident (git -C bypass): ~/.claude/postmortems/2026-03-31-git-dash-c-main-push.md

INPUT=$(cat) || exit 0
COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[ -z "$COMMAND" ] && exit 0

deny() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$1"
  exit 0
}

# ── Red line: git -C wholesale ban (incl. quoted forms) — bypasses cwd-based branch detection ──
if printf '%s\n' "$COMMAND" | grep -qE '(^|[;&|[:space:]])git[[:space:]]+["'"'"']?-C["'"'"']?([[:space:]]|=)'; then
  deny "❌ 禁用 git -C（会绕过分支保护 hook 的 cwd 检测）。请 cd 进仓库目录后执行 git。"
fi
# --git-dir / --work-tree 是 -C 的等价目录重定向，同样绕过 cwd 检测 → 一并禁用
if printf '%s\n' "$COMMAND" | grep -qE '(^|[;&|[:space:]])git[[:space:]][^|;&]*--(git-dir|work-tree)(=|[[:space:]])'; then
  deny "❌ 禁用 git --git-dir/--work-tree（与 git -C 同类，绕过分支保护检测）。请 cd 进仓库目录后执行 git。"
fi

# Skip unless the command contains a git write op (anywhere, incl. after cd/&&)
GITOP='(^|[;&|[:space:]])git([[:space:]]+-[^[:space:]]+([[:space:]]+[^-[:space:]][^[:space:]]*)?)*[[:space:]]+(commit|merge|push)\b'
printf '%s\n' "$COMMAND" | grep -qE "$GITOP" || exit 0

# ── Collect candidate run dirs: hook cwd + every `cd <path>` segment in the command ──
branch_of() {
  ( cd "$1" 2>/dev/null && { git symbolic-ref --short HEAD 2>/dev/null || git rev-parse --abbrev-ref HEAD 2>/dev/null; } )
}
ON_MAIN=false
B=$(branch_of "$PWD")
{ [ "$B" = "main" ] || [ "$B" = "master" ]; } && ON_MAIN=true
CD_TARGETS=$(printf '%s\n' "$COMMAND" \
  | grep -oE "(^|[;&|(\"']|[[:space:]])[[:space:]]*cd[[:space:]]+[^;&|]+" \
  | sed -E 's/.*cd[[:space:]]+//' \
  | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^"//;s/"$//')
if [ -n "$CD_TARGETS" ]; then
  for t in ${(f)CD_TARGETS}; do
    EXPANDED="${t/#\~/$HOME}"
    [ -d "$EXPANDED" ] || continue
    B=$(branch_of "$EXPANDED")
    { [ "$B" = "main" ] || [ "$B" = "master" ]; } && ON_MAIN=true
  done
fi

# Block: git commit / merge when any candidate dir is on main
if printf '%s\n' "$COMMAND" | grep -qE 'git([[:space:]]+-[^[:space:]]+([[:space:]]+[^-[:space:]][^[:space:]]*)?)*[[:space:]]+commit\b'; then
  [ "$ON_MAIN" = "true" ] && deny "❌ 禁止在 main 分支直接 commit（当前目录或命令内 cd 目标处于 main）。请先 git checkout -b <branch> 切分支后再提交。"
fi
if printf '%s\n' "$COMMAND" | grep -qE 'git([[:space:]]+-[^[:space:]]+([[:space:]]+[^-[:space:]][^[:space:]]*)?)*[[:space:]]+merge\b'; then
  [ "$ON_MAIN" = "true" ] && deny "❌ 禁止在 main 分支直接 merge。请通过 GitHub PR 合入 main。"
fi

# Block: git push with main/master as refspec TARGET (preceded by space or colon,
# followed by space or end) — feature branches merely containing "main" stay allowed.
if printf '%s\n' "$COMMAND" | grep -qE 'git([[:space:]]+-[^[:space:]]+([[:space:]]+[^-[:space:]][^[:space:]]*)?)*[[:space:]]+push([^|&;]*[[:space:]:])(main|master)([[:space:]]|$)'; then
  deny "❌ 禁止直接 push 到 main。请通过 GitHub PR 合入。"
fi

exit 0
