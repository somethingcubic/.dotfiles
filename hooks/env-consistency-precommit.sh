#!/usr/bin/env bash
# env-consistency-precommit.sh — PreToolUse hook on Bash.
# When Claude runs `git commit` AND any .env file is staged, run
# scripts/lint/check-env-consistency.sh. If it fails, block the commit
# so Claude must fix env-key drift before committing (avoids CI failure).

set -euo pipefail

INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty')
[[ "$TOOL" != "Bash" ]] && exit 0

CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
[[ -z "$CMD" ]] && exit 0

# Only intercept `git commit` (not `git commit-graph`, not commenting tools etc.)
echo "$CMD" | grep -qE '(^|[;&|[:space:]])git[[:space:]]+commit($|[[:space:]])' || exit 0

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -z "$REPO_ROOT" ]] && exit 0

# Only run if any staged file looks like an env file
STAGED_ENV=$(git -C "$REPO_ROOT" diff --cached --name-only 2>/dev/null \
  | grep -E '(^|/)\.env(\.[A-Za-z0-9_-]+)?$' || true)
[[ -z "$STAGED_ENV" ]] && exit 0

SCRIPT="$REPO_ROOT/scripts/lint/check-env-consistency.sh"
[[ ! -x "$SCRIPT" && ! -f "$SCRIPT" ]] && exit 0

if ! OUT=$(bash "$SCRIPT" 2>&1); then
  {
    echo "env-consistency check failed. Staged env files:"
    echo "$STAGED_ENV"
    echo
    echo "Script output:"
    echo "$OUT"
    echo
    echo "Fix env key drift (run: bash $SCRIPT) before committing."
  } >&2
  exit 2
fi

exit 0
