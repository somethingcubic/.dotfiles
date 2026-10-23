#!/bin/bash
# bash hooks/tests/workflow-model-gate.test.sh ；每个用例在 C 和 UTF-8 下各跑一次（桌面端调 hook 时是 C）。
hook="$(cd "$(dirname "$0")/.." && pwd)/workflow-model-gate.mjs"
fail=0
check() { # name expected_exit json
  local loc got
  for loc in C en_US.UTF-8; do
    printf '%s' "$3" | LC_ALL=$loc node "$hook" 2>/dev/null; got=$?
    if [ "$got" = "$2" ]; then echo "ok   $1 [$loc]"; else echo "FAIL $1 [$loc] (want $2 got $got)"; fail=1; fi
  done
}
wf() { # <meta.description> <agent() opts>
  local s="export const meta = { name: 'x', description: '$1' }
await agent('do it', { $2 })"
  jq -cn --arg s "$s" '{tool_name:"Workflow",tool_input:{script:$s}}'
}

check "齐全放行"                 0 "$(wf '[并行只读] 盘点' "model: 'opus', effort: 'medium'")"
check "缺标签拦截"               2 "$(wf '盘点三个目录' "model: 'opus', effort: 'medium'")"
check "缺 effort 拦截"           2 "$(wf '[独立验证] 审查' "model: 'opus'")"
check "并行修复带 worktree 放行" 0 "$(wf '[并行修复] 修三个测试' "model: 'opus', effort: 'medium', isolation: 'worktree'")"
check "并行修复不隔离拦截"       2 "$(wf '[并行修复] 修三个测试' "model: 'opus', effort: 'medium'")"
check "按名字调用不检查"         0 "$(jq -cn '{tool_name:"Workflow",tool_input:{name:"saved"}}')"
raw() { jq -cn --arg s "$1" '{tool_name:"Workflow",tool_input:{script:$s}}'; }
check "meta 外面的 description 不算" 2 "$(raw "export const meta = { name: 'x', description: '盘点' }
const r = { description: '[并行只读] fake' }
await agent('x', { model: 'opus', effort: 'low' })")"
check "meta 字符串里写的 description 不算" 2 "$(raw "export const meta = { name: 'x', whenToUse: \"description: '[并行只读]'\", description: '盘点' }
await agent('x', { model: 'opus', effort: 'low' })")"
check "isolation 写在字符串里不算" 2 "$(raw "export const meta = { name: 'x', description: '[并行修复] 修' }
await agent(\"isolation: 'worktree'\", { model: 'opus', effort: 'low', isolation: 'none' })")"
check "model 写在 prompt 里不算"   2 "$(raw "export const meta = { name: 'x', description: '[并行只读] 盘点' }
await agent('model: x effort: y', {})")"
check "给 agent 起别名拦截"        2 "$(raw "export const meta = { name: 'x', description: '[并行只读] 盘点' }
const f = agent
await f('x', {})")"
check "模板字符串 description 放行" 0 "$(raw "export const meta = { name: 'x', description: \`[独立验证] 审查\` }
await agent(\`p \${1}\`, { model: 'opus', effort: 'high', label: 'r' })")"
check "注释里的 meta 不算"          2 "$(raw "// export const meta = { description: '[并行只读] x' }
export const meta = { name: 'x', description: '盘点' }
await agent('x', { model: 'opus', effort: 'low' })")"
check "globalThis.agent 拦截"       2 "$(raw "export const meta = { name: 'x', description: '[并行只读] 盘点' }
await globalThis.agent('x', {})")"
check "带引号的键名放行"            0 "$(raw "export const meta = { name: 'x', description: '[并行只读] 盘点' }
await agent('x', { 'model': 'opus', \"effort\": 'low' })")"
check "输入不是 JSON 放行"          0 "not json"
exit $fail
