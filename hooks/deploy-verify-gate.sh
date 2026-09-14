#!/bin/zsh
# deploy-verify-gate.sh — Global PreToolUse hook (Bash matcher)
#
# WHY THIS EXISTS
# ---------------
# 2026-08-26: a one-line DSN change (interpolateParams) was deployed to the
# refresh server. Client-side interpolation renders []byte as _binary'...'
# literals, which MySQL rejects for JSON columns (Error 3144). Refresh step
# creation writes JSON via []byte, so scheduling died on every platform:
# 44,360 errors, 12.5 hours of ZERO refreshes, +300k overdue creators.
#
# It went unnoticed for 12.5 hours because post-deploy "verification" looked
# only at DB metrics. CPU fell 100%->24% and QPS fell 8,400->1,795; both were
# read as "the optimisation worked". They were actually the signature of a
# system that had stopped doing any work. The service's own error log had been
# screaming Error 3144 since minute one and was never opened.
#
# WHAT THIS GATE ENFORCES
# -----------------------
# After restarting a production service, you may not declare anything about the
# result until you have actually read that service's error log. The gate makes
# the cheap, decisive check unskippable — it does not trust intent.
#
# Flow:
#   1. A production restart sets a pending marker naming the services.
#   2. While the marker is pending, commands that read error logs clear it.
#   3. Any *further* production restart is DENIED until the pending check is
#      cleared, so failures cannot be stacked on top of each other unnoticed.
#
# The marker is advisory for reads (it never blocks log inspection — that is
# the thing we want to happen) and blocking for the next mutation.

INPUT=$(cat) || exit 0
TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null) || exit 0
[ "$TOOL" != "Bash" ] && exit 0

CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[ -z "$CMD" ] && exit 0

STATE_DIR="${HOME}/.claude/state"
MARKER="${STATE_DIR}/pending-deploy-verify"
mkdir -p "$STATE_DIR" 2>/dev/null

CMD_FLAT=$(printf '%s\n' "$CMD" | tr -s '[:space:]' ' ')

# Production hosts. Restarts elsewhere (test1-4) are out of scope: those are
# not what caused the outage and gating them would only add friction.
PROD_HOSTS='8\.222\.139\.116|8\.219\.202\.238|47\.237\.255\.14|47\.84\.136\.146'

is_prod_restart() {
    printf '%s\n' "$CMD_FLAT" | grep -qE "$PROD_HOSTS" || return 1
    printf '%s\n' "$CMD_FLAT" | grep -qE 'supervisorctl[[:space:]]+(restart|start)|systemctl[[:space:]]+(restart|start)' || return 1
    return 0
}

# A verification command is one that reads an error/failure signal from logs.
# Reading metrics, status, or the DB does NOT count — that is exactly the
# substitution that hid the outage.
is_log_check() {
    printf '%s\n' "$CMD_FLAT" | grep -qE '\.err\.log|err\.log|journalctl|supervisorctl[[:space:]]+tail' || return 1
    printf '%s\n' "$CMD_FLAT" | grep -qiE 'grep|tail|awk|wc|cut|less|cat' || return 1
    return 0
}

# ── Clear the marker once the error log has actually been read ──────────────
if [ -f "$MARKER" ] && is_log_check; then
    rm -f "$MARKER" 2>/dev/null
    exit 0
fi

# ── Block a second production restart while a check is still owed ───────────
if [ -f "$MARKER" ] && is_prod_restart; then
    PENDING=$(cat "$MARKER" 2>/dev/null | head -1)
    cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "🚫 上一次生产重启($PENDING)的错误日志还没查，不允许继续重启。\n\n先做这一步（不是看 CPU/QPS/status，是看服务自己的错误日志）：\n  ssh -o ConnectTimeout=10 -o ServerAliveInterval=5 root@<host> 'tail -n 3000 /var/log/supervisor/<service>.err.log | grep -cE \"\\\\[ERROR\\\\]\"'\n\n2026-08-26 教训：只看 DB 指标 → CPU 100%→24%、QPS 8400→1795 被当成优化成功，实际是调度全挂；错误日志里 44,360 条 Error 3144 无人查看，刷新停摆 12.5 小时、逾期 +30 万。\n指标下降可能是故障信号，只有错误日志能区分。"
  }
}
EOF
    exit 0
fi

# ── Arm the marker on a production restart ─────────────────────────────────
if is_prod_restart; then
    SVC=$(printf '%s\n' "$CMD_FLAT" | grep -oE '(supervisorctl|systemctl)[[:space:]]+(restart|start)[[:space:]]+[^;|&]*' | head -1 | cut -c1-120)
    printf '%s\n' "${SVC:-production restart}" > "$MARKER" 2>/dev/null
    cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "additionalContext": "⚠️ 生产重启已记录。部署后验证的第一步必须是读该服务的错误日志（.err.log / journalctl），不是 CPU、QPS 或 supervisorctl status。\n在错误日志被检查前，下一次生产重启会被拒绝。\n\n另外两条同样必须做：\n  2) 看业务量本身（每小时完成多少次刷新），不是看 DB 忙不忙\n  3) 任何指标出现超出预期的变化，默认按故障处理直到排除——指标暴跌往往是系统停止工作，不是优化生效"
  }
}
EOF
    exit 0
fi

exit 0
