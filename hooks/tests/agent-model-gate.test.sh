#!/bin/bash
# bash hooks/tests/agent-model-gate.test.sh ；每个用例在 C 和 UTF-8 下各跑一次（桌面端调 hook 时是 C）。
hook="$(cd "$(dirname "$0")/.." && pwd)/agent-model-gate.sh"
fail=0
check() { # name expected_exit json
  local loc got
  for loc in C en_US.UTF-8; do
    printf '%s' "$3" | LC_ALL=$loc /bin/bash "$hook" 2>/dev/null; got=$?
    if [ "$got" = "$2" ]; then echo "ok   $1 [$loc]"; else echo "FAIL $1 [$loc] (want $2 got $got)"; fail=1; fi
  done
}
# agent <description> [model] [effort] [subagent_type] [isolation]
agent() {
  jq -cn --arg d "$1" --arg m "${2-opus}" --arg e "${3-medium}" --arg t "${4-general-purpose}" --arg i "${5-}" \
    '{tool_name:"Agent",tool_input:({prompt:"x",description:$d,subagent_type:$t}
      + (if $m=="" then {} else {model:$m} end) + (if $e=="" then {} else {effort:$e} end)
      + (if $i=="" then {} else {isolation:$i} end))}'
}

check "齐全放行"                  0 "$(agent '[并行只读] 盘点三个目录')"
check "四种标签都放行 独立验证"   0 "$(agent '[独立验证] 审查 hook 正则')"
check "四种标签都放行 大范围读取" 0 "$(agent '[大范围读取] 读 4GB transcript')"
check "开头有空格放行"            0 "$(agent ' [独立验证] 审查')"
check "缺标签拦截"                2 "$(agent '盘点三个目录')"
check "标签不在开头拦截"          2 "$(agent '盘点 [并行只读]')"
check "缺 model 拦截"             2 "$(agent '[并行只读] 盘点' '')"
check "缺 effort 拦截"            2 "$(agent '[并行只读] 盘点' opus '')"
check "并行修复不隔离拦截"        2 "$(agent '[并行修复] 修 test_a')"
check "并行修复带 worktree 放行"  0 "$(agent '[并行修复] 修 test_a' opus medium general-purpose worktree)"
check "标签在第二行拦截"          2 "$(agent "盘点
[并行只读]")"
check "fork 不检查"               0 "$(agent '改 a.go' '' '' fork)"
check "输入不是 JSON 放行"        0 "not json"
exit $fail
