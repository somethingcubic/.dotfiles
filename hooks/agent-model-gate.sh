#!/bin/bash
# agent-model-gate.sh — PreToolUse(Agent): 派子 agent 时必须显式指定 model 和 effort，按任务体量和难度选档（判断依据见 AGENTS.md「子 agent 选模型」）；
#   description 必须以类型标签开头（判断依据见 AGENTS.md「要不要开子 agent」），[并行修复] 还必须带 isolation: "worktree"。
# fork 类型继承父 agent 的模型和上下文，不检查。
export LC_ALL=C

input=$(cat)
# 没有 jq 或输入不是 JSON 时放行（和其他 hook 一致），不把所有 Agent 调用都拦掉
command -v jq >/dev/null 2>&1 || exit 0
jq -e . >/dev/null 2>&1 <<<"$input" || exit 0
type=$(jq -r '.tool_input.subagent_type // empty' <<<"$input")
[ "$type" = "fork" ] && exit 0

model=$(jq -r '.tool_input.model // empty' <<<"$input")
effort=$(jq -r '.tool_input.effort // empty' <<<"$input")
desc=$(jq -r '.tool_input.description // empty' <<<"$input")
isolation=$(jq -r '.tool_input.isolation // empty' <<<"$input")

missing=()
[ -z "$model" ] && missing+=("model")
[ -z "$effort" ] && missing+=("effort")
tag=$(head -n1 <<<"$desc" | grep -oE '^[[:space:]]*\[(并行只读|独立验证|大范围读取|并行修复)\]')
[ -z "$tag" ] && missing+=("description 开头的类型标签")
if grep -q '并行修复' <<<"$tag" && [ "$isolation" != "worktree" ]; then
  missing+=('isolation: "worktree"（[并行修复] 必须隔离）')
fi
[ ${#missing[@]} -eq 0 ] && exit 0

list=$(printf '%s、' "${missing[@]}"); list=${list%、}
echo "agent-model-gate: 派子 agent 缺 ${list}。model/effort 按 AGENTS.md「子 agent 选模型」判断：做错的代价、难度在推理还是在读得多（读得多就拆分）、能否便宜地验证。类型标签按 AGENTS.md「要不要开子 agent」选一个：[并行只读] [独立验证] [大范围读取] [并行修复]；四种都不是就别开子 agent，在主会话里做。" >&2
exit 2
