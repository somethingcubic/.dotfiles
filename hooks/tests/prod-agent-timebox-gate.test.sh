#!/bin/bash
# 负例和正例测试：bash hooks/tests/prod-agent-timebox-gate.test.sh
hook="$(cd "$(dirname "$0")/.." && pwd)/prod-agent-timebox-gate.sh"
fail=0
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

check() { # name expected_exit json
  printf '%s' "$3" | bash "$hook" 2>/dev/null
  local got=$?
  if [ "$got" = "$2" ]; then echo "ok   $1"; else echo "FAIL $1 (want $2 got $got)"; fail=1; fi
}

agent() { jq -cn --arg p "$1" --arg t "${2:-general-purpose}" '{tool_name:"Agent",tool_input:{prompt:$p,subagent_type:$t}}'; }
wf() { jq -cn --arg s "$1" '{tool_name:"Workflow",tool_input:{script:$s}}'; }

check "非生产任务放行"            0 "$(agent '读 internal/foo.go 总结调用链')"
check "提到 ssh 没写时限拦截"      2 "$(agent 'ssh 到 refresh 机查日志')"
check "提到生产 IP 没写时限拦截"   2 "$(agent '在 8.219.202.238 上跑 SQL')"
check "提到 prod 没写时限拦截"     2 "$(agent 'query prod mysql for counts')"
check "提到生产没写时限拦截"       2 "$(agent '查生产库失败行数')"
check "写了时限放行"              0 "$(agent '查生产库失败行数。时限：30 分钟，≤15 条 SQL，超时就交已有结果')"
check "半角冒号和 ≤ 放行"          0 "$(agent 'ssh refresh 查日志 时限: ≤20分钟')"
check "时限超过 120 拦截"          2 "$(agent 'ssh 查日志 时限：300 分钟')"
check "只写超时两个字拦截"         2 "$(agent 'ssh 查日志，超时就交结果')"
check "product 不算 prod"          0 "$(agent 'review the product page copy')"
check "fork 不检查"               0 "$(agent 'ssh 查日志' fork)"
check "workflow 涉及生产没时限拦截" 2 "$(wf "agent('ssh prod 查 SQL', {model:'sonnet', effort:'low'})")"
check "workflow 写了时限放行"       0 "$(wf "agent('ssh prod 查 SQL。时限：30 分钟', {model:'sonnet', effort:'low'})")"
printf '%s' "agent('查生产库')" > "$tmp/w.js"
check "workflow scriptPath 也检查"  2 "$(jq -cn --arg p "$tmp/w.js" '{tool_name:"Workflow",tool_input:{scriptPath:$p}}')"
check "其他工具不检查"             0 '{"tool_name":"Bash","tool_input":{"command":"ssh prod"}}'

exit $fail
