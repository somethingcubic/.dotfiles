#!/bin/bash
# evals/run.sh — 无头跑规则 eval。每个用例把夹具复制到临时目录，用 claude -p 跑 N 次，check.py 判分，汇总写到 results/<label>.json。
# 用法：bash evals/run.sh <label> [次数，默认 3] [用例…，默认 E1 E2 E3 E4]
#   比较两轮：python3 -I evals/check.py --compare evals/results/<基线>.json evals/results/<新>.json
# 每次运行花费上限 1.5 美元、墙钟上限 15 分钟；不加载 MCP（避免外发）；全局 AGENTS.md、lessons、hooks 照常加载，测的就是它们。
# 子进程用干净环境启动，不继承桌面 App 会话的 CLAUDE_CODE_* 变量（代理变量照传）。
# 临时目录在退出时删除；没通过的运行把原始记录留在 evals/.runs/<label>/ 供复查（已 gitignore，看完自己删）。
set -u
here=$(cd "$(dirname "$0")" && pwd)
label=${1:?用法: run.sh <label> [次数] [用例…]}
shift
reps=3
if [ $# -gt 0 ] && [[ $1 =~ ^[0-9]+$ ]]; then reps=$1; shift; fi
cases=("$@"); [ ${#cases[@]} -eq 0 ] && cases=(E1 E2 E3 E4)
work=$(mktemp -d "${TMPDIR:-/tmp}/agent-eval.XXXXXX")
trap 'rm -rf "$work"' EXIT
keep="$here/.runs/$label"
export here work keep

run_one() {
  local id=$1 case=${1%-*} dir="$work/$1" prompt
  local proxy=()
  for v in HTTPS_PROXY HTTP_PROXY ALL_PROXY NO_PROXY https_proxy http_proxy all_proxy no_proxy; do
    [ -n "${!v:-}" ] && proxy+=("$v=${!v}")
  done
  mkdir -p "$dir" && cp -R "$here/fixtures/$case/." "$dir/"
  prompt=$(cat "$dir/prompt.txt") && rm "$dir/prompt.txt"
  [ -f "$dir/env.fixture" ] && mv "$dir/env.fixture" "$dir/.env"
  if [ -f "$dir/GIT_INIT" ]; then
    rm "$dir/GIT_INIT"
    (cd "$dir" && git init -q -b main && git add -A && git -c user.name=eval -c user.email=eval@localhost commit -qm init)
  fi
  (cd "$dir" && env -i HOME="$HOME" PATH="$PATH" USER="$USER" SHELL="$SHELL" TMPDIR="${TMPDIR:-/tmp}" LANG=en_US.UTF-8 \
    ${proxy[@]+"${proxy[@]}"} timeout 900 claude -p "$prompt" --output-format stream-json --verbose --max-budget-usd 1.5 \
      --permission-mode acceptEdits --strict-mcp-config --no-session-persistence \
      --allowedTools Bash Read Edit Write Agent Workflow \
    > "$work/$id.jsonl" 2> "$work/$id.err" < /dev/null)
  python3 -I "$here/check.py" "$case" "$work/$id.jsonl" "$dir" > "$work/$id.result.json"
  if ! grep -q '"pass": true' "$work/$id.result.json"; then
    mkdir -p "$keep" && cp "$work/$id.jsonl" "$work/$id.err" "$work/$id.result.json" "$keep/" 2>/dev/null
  fi
  printf '%s %s\n' "$id" "$(head -c 300 "$work/$id.result.json")"
}
export -f run_one

ids=()
for c in "${cases[@]}"; do for r in $(seq 1 "$reps"); do ids+=("$c-$r"); done; done
printf '%s\n' "${ids[@]}" | xargs -P 6 -I{} bash -c 'run_one {}'
python3 -I "$here/check.py" --aggregate "$here/results/$label.json" "$label" "$work"/*.result.json
