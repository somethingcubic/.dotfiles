#!/bin/bash
# agent-model-gate.sh — PreToolUse(Agent): 派子 agent 时必须显式指定 model 和 effort，按任务体量和难度选档（档位表见 AGENTS.md「并行」一条）。
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
echo "agent-model-gate: 派子 agent 必须显式指定 ${missing}。按 AGENTS.md 档位表选：检索/机械 → haiku+low；常规实现 → sonnet+medium；spec/review/复杂调试 → opus+high。" >&2
exit 2
