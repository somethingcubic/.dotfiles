#!/usr/bin/env bash
# go-format.sh — PostToolUse hook: auto-format Go files after Edit/Write.
# Runs gofmt -w (always) and goimports -w (if installed).
# Silent on success; never blocks Claude.

set -euo pipefail

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

[[ -z "$FILE_PATH" ]] && exit 0
[[ "$FILE_PATH" != *.go ]] && exit 0
[[ ! -f "$FILE_PATH" ]] && exit 0

gofmt -w "$FILE_PATH" 2>/dev/null || true

if command -v goimports >/dev/null 2>&1; then
  goimports -w "$FILE_PATH" 2>/dev/null || true
fi

exit 0
