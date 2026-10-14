#!/bin/bash
# prod-agent-timebox-gate.sh — PreToolUse(Agent|Workflow): 派去查生产的子 agent / workflow 必须写明时长上限。
# 起因：2026-10-10、2026-10-13 两次后台任务长时间不汇报（后一次查生产的节点跑了 24 小时）。
# 判定：prompt（Agent）或脚本（Workflow）提到生产主机、ssh、prod 或「生产」时，必须含显式标记
#   时限：<N> 分钟     （冒号全角半角都可，N ≤ 120）
# 标记写在 prompt 里，子 agent 看得到；超时就交已有结果。hook 不检查 orchestrator 有没有按时查进度。

input=$(cat)
tool=$(jq -r '.tool_name // empty' <<<"$input")

case "$tool" in
  Agent)
    [ "$(jq -r '.tool_input.subagent_type // empty' <<<"$input")" = "fork" ] && exit 0
    text=$(jq -r '.tool_input.prompt // empty' <<<"$input")
    ;;
  Workflow)
    path=$(jq -r '.tool_input.scriptPath // empty' <<<"$input")
    if [ -n "$path" ]; then
      text=$(cat "$path" 2>/dev/null) || exit 0
    else
      text=$(jq -r '.tool_input.script // empty' <<<"$input")
    fi
    ;;
  *) exit 0 ;;
esac
[ -z "$text" ] && exit 0

prod_re='8\.219\.202\.238|8\.222\.139\.116|(^|[^A-Za-z])(ssh|prod)([^A-Za-z]|$)|生产'
grep -qiE "$prod_re" <<<"$text" || exit 0

minutes=$(grep -oE '时限[:：][[:space:]]*≤?[[:space:]]*[0-9]+[[:space:]]*分钟' <<<"$text" | grep -oE '[0-9]+' | head -1)
if [ -n "$minutes" ] && [ "$minutes" -ge 1 ] && [ "$minutes" -le 120 ]; then
  exit 0
fi

if [ -n "$minutes" ]; then
  echo "prod-agent-timebox-gate: 时限 ${minutes} 分钟超过 120 分钟上限。拆成更小的任务，或先问用户。" >&2
else
  echo "prod-agent-timebox-gate: 这个${tool}涉及生产（ssh / prod / 生产主机），prompt 里要写明「时限：<N> 分钟」（N ≤ 120），并写上查询条数上限和「超时就交已有结果」。启动后按 lessons 2026-10-10 每 30 分钟查一次进度。" >&2
fi
exit 2
