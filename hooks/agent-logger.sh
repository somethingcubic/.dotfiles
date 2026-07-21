#!/usr/bin/env zsh
# ~/.claude/hooks/agent-logger.sh
# Trigger: SubagentStop
# Logs agent execution details for observability in long sessions.

INPUT=$(cat)
AGENT_NAME=$(echo "$INPUT" | jq -r '.agent_type // "unnamed"')
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

LOG_DIR="$HOME/.claude/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/agents_$(date '+%Y%m%d').log"

LAST_MSG=$(echo "$INPUT" | jq -r '.last_assistant_message // "no output"' | head -50)

cat >> "$LOG_FILE" <<EOF
[$TIMESTAMP] Agent: $AGENT_NAME
---
$LAST_MSG
===
EOF

exit 0
