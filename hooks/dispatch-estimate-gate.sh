#!/bin/bash
# dispatch-estimate-gate.sh — PreToolUse(Agent|Workflow): 派去写代码、开 PR 的子 agent / workflow 必须先按工作量估时，时限不能远大于估计。
# 起因：2026-10-21 同日两次被用户问「为什么要这么久」。派单 prompt 里塞了读无关文档、跑多个目录的全量测试、本地截图，
#   时限写 60–90 分钟，给用户报的预计时间也照时限报（报 45 分钟，实际 23 分钟开出 PR）。
# 判定：prompt（Agent，fork 除外）或脚本（Workflow）里出现 gh pr create / git push / 开 PR 时，必须同时有
#   预计：<K> 分钟   和   时限：<N> 分钟（冒号全角半角都可，可写 ≤）
#   且每个时限 N ≤ max(15, 1.5 × 最大的 K)。给用户报时间用 K，不用 N。
export LC_ALL=C

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
grep -qiE 'gh pr create|git push|开 ?PR' <<<"$text" || exit 0

# 「：」「≤」按字节各占 3 个，写成分组（同 prod-agent-timebox-gate.sh）。
num() { grep -oE "$1(:|：)[[:space:]]*(≤)?[[:space:]]*[0-9]+[[:space:]]*分钟" <<<"$text" | grep -oE '[0-9]+'; }
est=$(num '预计' | sort -n | tail -1)
limits=$(num '时限')

defaults="派单默认：只跑改动直接相关的测试（不跑多个目录的全量），不读与改动无关的文档，截图等部署到测试机后再看；给用户报的时间用「预计」，不用时限。"
if [ -z "$est" ] || [ -z "$limits" ]; then
  echo "dispatch-estimate-gate: 这个${tool}要写代码或开 PR，prompt 里要按实际工作量写「预计：<K> 分钟」，并写「时限：<N> 分钟」（N ≤ max(15, 1.5K)）。${defaults}" >&2
  exit 2
fi
cap=$(( est * 3 / 2 ))
[ "$cap" -lt 15 ] && cap=15
for n in $limits; do
  if [ "$n" -gt "$cap" ]; then
    echo "dispatch-estimate-gate: 时限 ${n} 分钟超过预计 ${est} 分钟的 1.5 倍（上限 ${cap}）。先砍掉派单里不必要的步骤，或把预计改成真实工作量。${defaults}" >&2
    exit 2
  fi
done
exit 0
