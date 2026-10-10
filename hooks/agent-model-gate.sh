#!/bin/bash
# agent-model-gate.sh — PreToolUse(Agent): 派子 agent 时必须显式指定 model 和 effort，按任务体量和难度选档（判断依据见 AGENTS.md「子 agent 选模型」）。
# fork 类型继承父 agent 的模型，不检查。

input=$(cat)
type=$(jq -r '.tool_input.subagent_type // empty' <<<"$input")
[ "$type" = "fork" ] && exit 0

model=$(jq -r '.tool_input.model // empty' <<<"$input")
effort=$(jq -r '.tool_input.effort // empty' <<<"$input")
[ -n "$model" ] && [ -n "$effort" ] && exit 0

missing=""
[ -z "$model" ] && missing="model"
[ -z "$effort" ] && missing="${missing:+$missing 和 }effort"
echo "agent-model-gate: 派子 agent 必须显式指定 ${missing}。按 AGENTS.md「子 agent 选模型」判断：做错的代价、难度在推理还是在读得多（读得多就拆分）、能否便宜地验证。" >&2
exit 2
