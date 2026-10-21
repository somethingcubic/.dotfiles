#!/bin/bash
# bash hooks/tests/dispatch-estimate-gate.test.sh ；每个用例在 C 和 UTF-8 下各跑一次（桌面端调 hook 时是 C）。
hook="$(cd "$(dirname "$0")/.." && pwd)/dispatch-estimate-gate.sh"
fail=0
check() { # name expected_exit json
  local loc got
  for loc in C en_US.UTF-8; do
    printf '%s' "$3" | LC_ALL=$loc /bin/bash "$hook" 2>/dev/null; got=$?
    if [ "$got" = "$2" ]; then echo "ok   $1 [$loc]"; else echo "FAIL $1 [$loc] (want $2 got $got)"; fail=1; fi
  done
}
agent() { jq -cn --arg p "$1" --arg t "${2:-general-purpose}" '{tool_name:"Agent",tool_input:{prompt:$p,subagent_type:$t}}'; }
wf() { jq -cn --arg s "$1" '{tool_name:"Workflow",tool_input:{script:$s}}'; }
both() { check "Agent    $1" "$2" "$(agent "$3")"; check "Workflow $1" "$2" "$(wf "agent('$3', {model:'sonnet', effort:'low'})")"; }

P='gh pr'; C='create'; G='git'; U='push'   # 拆开写：整串出现在命令行里会被 cmd-guards 当成真的开 PR
both "不写代码的任务放行"            0 '读 internal/foo.go 总结调用链。时限：60 分钟'
both "开 PR 没写预计拦截"           2 "改 a.go 然后 ${P} ${C}。时限：30 分钟"
both "开 PR 没写时限拦截"           2 "改 a.go 然后 ${G} ${U}。预计：20 分钟"
both "时限在 1.5 倍内放行"          0 '改 a.go，开 PR。预计：20 分钟。时限：30 分钟'
both "时限超过 1.5 倍拦截"          2 "改 a.go，${P} ${C}。预计：20 分钟。时限：60 分钟"
both "小任务时限 15 分钟放行"        0 "改文案 ${G} ${U}。预计：5 分钟 时限：15 分钟"
both "小任务时限 16 分钟拦截"        2 "改文案 ${G} ${U}。预计：5 分钟 时限：16 分钟"
both "半角冒号和 ≤ 放行"            0 '改 a.go 开PR。预计: 40 分钟 时限: ≤60分钟'
both "两个时限有一个超就拦截"        2 '改 a.go 开 PR。预计：20 分钟 时限：30 分钟 时限：90 分钟'
check "fork 放行"                  0 "$(agent "改 a.go 然后 ${P} ${C}" fork)"
exit $fail
