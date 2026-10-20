#!/bin/bash
# 负例和正例测试：bash hooks/tests/prod-agent-timebox-gate.test.sh
# 每个用例在 C 和 UTF-8 两种 locale 下各跑一次。2026-10-20 前的写法在 UTF-8 下认得「时限：30 分钟」，
# 在 C 下认不出（桌面端调 hook 时就是 C），只按一种 locale 跑发现不了。
hook="$(cd "$(dirname "$0")/.." && pwd)/prod-agent-timebox-gate.sh"
fail=0
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

check() { # name expected_exit json
  local loc got
  for loc in C en_US.UTF-8; do
    printf '%s' "$3" | LC_ALL=$loc /bin/bash "$hook" 2>/dev/null
    got=$?
    if [ "$got" = "$2" ]; then echo "ok   $1 [$loc]"; else echo "FAIL $1 [$loc] (want $2 got $got)"; fail=1; fi
  done
}

agent() { jq -cn --arg p "$1" --arg t "${2:-general-purpose}" '{tool_name:"Agent",tool_input:{prompt:$p,subagent_type:$t}}'; }
wf() { jq -cn --arg s "$1" '{tool_name:"Workflow",tool_input:{script:$s}}'; }
both() { # name expected_exit text：同一段文字分别作为 Agent 的 prompt 和 Workflow 脚本里 agent() 的提示词
  check "Agent    $1" "$2" "$(agent "$3")"
  check "Workflow $1" "$2" "$(wf "agent('$3', {model:'sonnet', effort:'low'})")"
}

both "非生产任务放行"              0 '读 internal/foo.go 总结调用链'
both "提到 ssh 没写时限拦截"        2 'ssh 到 refresh 机查日志'
both "提到生产 IP 没写时限拦截"     2 '在 8.219.202.238 上跑 SQL'
both "提到 prod 没写时限拦截"       2 'query prod mysql for counts'
both "提到生产没写时限拦截"         2 '查生产库失败行数'
both "全角冒号放行"                0 '查生产库失败行数。时限：30 分钟，≤15 条 SQL，超时就交已有结果'
both "半角冒号放行"                0 'ssh refresh 查日志。时限: 40 分钟'
both "全角冒号加 ≤ 放行"            0 'ssh refresh 查日志。时限：≤40 分钟'
both "半角冒号加 ≤ 和空格放行"       0 'ssh refresh 查日志。时限: ≤ 40 分钟'
both "半角冒号加 ≤ 不带空格放行"     0 'ssh refresh 查日志 时限: ≤20分钟'
both "时限 120 放行"               0 'ssh 查日志 时限：120 分钟'
both "时限 121 拦截"               2 'ssh 查日志 时限: ≤121 分钟'
both "时限超过 120 拦截"            2 'ssh 查日志 时限：300 分钟'
both "缺冒号拦截"                  2 'ssh 查日志 时限 30 分钟'
both "冒号后是全角空格拦截"         2 'ssh 查日志 时限：　40 分钟'
both "只写超时两个字拦截"           2 'ssh 查日志，超时就交结果'
check "product 不算 prod"          0 "$(agent 'review the product page copy')"
check "fork 不检查"                0 "$(agent 'ssh 查日志' fork)"
printf '%s' "agent('查生产库')" > "$tmp/w.js"
check "workflow scriptPath 没时限拦截" 2 "$(jq -cn --arg p "$tmp/w.js" '{tool_name:"Workflow",tool_input:{scriptPath:$p}}')"
printf '%s' "agent('查生产库。时限：30 分钟')" > "$tmp/ok.js"
check "workflow scriptPath 写了时限放行" 0 "$(jq -cn --arg p "$tmp/ok.js" '{tool_name:"Workflow",tool_input:{scriptPath:$p}}')"
check "其他工具不检查"             0 '{"tool_name":"Bash","tool_input":{"command":"ssh prod"}}'

exit $fail
