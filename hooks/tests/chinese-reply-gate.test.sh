#!/bin/bash
# 负例和正例测试：bash hooks/tests/chinese-reply-gate.test.sh
# 回复文字取自 2026-10-19 调度会话里漏拦的两段英文回复和一段正常的中文回复。
hook="$(cd "$(dirname "$0")/.." && pwd)/chinese-reply-gate.py"
fail=0
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

EN_LAST="I'm not sure, and I said it too confidently last time. When I said they were waiting for your confirmation, that came from the last update before the context compaction, and I didn't re-check."
EN_PROGRESS="I've sent your request to the ai-decision-accuracy task (fable model, was idle). It will use htmldrop to turn the report into HTML."
ZH="我已经让 \`taskhub-send-running\` 合并 PR #9。那两件事它不再做：上一轮通知可能丢，以及加仓库时直接发通知。它会先把 PR 从 draft 转成正式 PR，确认检查通过后合并。

我还让它多做了一步：按 taskhub 文档里写的方式，更新本机正在用的 taskhub。只合并不更新的话，本机的 \`task send\` 还是旧版，任务运行时照样发不了消息。"

prompt() { jq -cn --arg t "$1" '{type:"user",message:{role:"user",content:$t}}'; }
text() { jq -cn --arg t "$1" '{type:"assistant",message:{role:"assistant",content:[{type:"text",text:$t}]}}'; }
tool() { jq -cn '{type:"assistant",message:{role:"assistant",content:[{type:"tool_use",id:"toolu_1",name:"Bash",input:{command:"task ls --pr"}}]}}'; }
result() { jq -cn '{type:"user",message:{role:"user",content:[{type:"tool_result",tool_use_id:"toolu_1",content:"ok"}]}}'; }
think() { jq -cn '{type:"assistant",message:{role:"assistant",content:[{type:"thinking",thinking:""}]}}'; }

stop() { # transcript_path [last_assistant_message] [stop_hook_active]
  jq -cn --arg p "$1" --arg m "${2-}" --argjson a "${3:-false}" \
    '{hook_event_name:"Stop",stop_hook_active:$a,transcript_path:$p} + (if $m == "" then {} else {last_assistant_message:$m} end)'
}

check() { # name want(block|pass) stdin_json [reason 里应出现的文字]
  local out got
  out=$(printf '%s' "$3" | python3 "$hook" 2>&1)
  if printf '%s' "$out" | grep -q '"decision": "block"'; then got=block; else got=pass; fi
  if [ "$got" != "$2" ]; then echo "FAIL $1 (want $2 got $got) $out"; fail=1; return; fi
  if [ -n "${4-}" ] && ! printf '%s' "$out" | grep -qF "$4"; then echo "FAIL $1 (reason 缺「$4」) $out"; fail=1; return; fi
  echo "ok   $1"
}

# 漏拦现场：hook 启动时记录文件停在 thinking，最后一段英文回复还没写入
{ prompt '你是说inbound-mail-triggers里面的PR还没合？'; tool; result; think; } > "$tmp/race.jsonl"
{ cat "$tmp/race.jsonl"; text "$EN_LAST"; } > "$tmp/full.jsonl"
{ prompt '这个 task 现在什么状态？'; text "$EN_PROGRESS"; tool; result; } > "$tmp/progress.jsonl"
{ prompt '合并 PR #9'; tool; result; text "$ZH"; } > "$tmp/zh.jsonl"
{ prompt '状态？'; text "$EN_LAST"; prompt 'Stop hook feedback: chinese-reply-gate'; text "$ZH"; } > "$tmp/corrected.jsonl"

check "记录缺最后一段，stdin 带英文回复：拦"      block "$(stop "$tmp/race.jsonl" "$EN_LAST")" "本轮有 1 段"
check "记录已写入最后一段，stdin 同一段：只算 1 段" block "$(stop "$tmp/full.jsonl" "$EN_LAST")" "本轮有 1 段"
check "记录里有英文进度短句，最后一段中文：拦"    block "$(stop "$tmp/progress.jsonl" "$ZH")" "本轮有 1 段"
check "stdin 没有该字段，记录完整英文：拦"        block "$(stop "$tmp/full.jsonl")"
check "记录文件读不到，stdin 英文：拦"            block "$(stop "$tmp/missing.jsonl" "$EN_LAST")"
check "记录缺最后一段，stdin 中文：放行"          pass  "$(stop "$tmp/race.jsonl" "$ZH")"
check "记录完整中文回复：放行"                    pass  "$(stop "$tmp/zh.jsonl" "$ZH")"
check "上一轮英文已被纠正，本轮中文：放行"        pass  "$(stop "$tmp/corrected.jsonl" "$ZH")"
check "stop_hook_active 放行"                     pass  "$(stop "$tmp/race.jsonl" "$EN_LAST" true)"

exit $fail
