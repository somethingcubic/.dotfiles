#!/bin/bash
# bash hooks/tests/merge-untested-gate.test.sh ；每个用例在 C 和 UTF-8 下各跑一次（桌面端调 hook 时是 C）。
# gh 用 PATH 桩替掉：桩把 $GH_STUB_JSON 原样输出；GH_STUB_FAIL=1 时退出码 1。
# HOOK=<别的文件> 可以换掉被测 hook（变异：换成空脚本时「无小节」用例必须 FAIL）。
hook="${HOOK:-$(cd "$(dirname "$0")/.." && pwd)/merge-untested-gate.py}"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/repo"
cat > "$tmp/bin/gh" <<'EOF'
#!/bin/bash
[ "$GH_STUB_FAIL" = 1 ] && { echo "HTTP 502" >&2; exit 1; }
printf '%s' "$GH_STUB_JSON"
EOF
chmod +x "$tmp/bin/gh"
git -c init.defaultBranch=main init -q "$tmp/repo" && (cd "$tmp/repo" && git remote add origin git@github.com:OrdoAI/ordo-platform.git)
fail=0
check() { # name expected_exit command pr_json [gh_fail]；command 以 MCP: 开头时是 GitHub MCP 合并，格式 MCP:<owner>/<repo>/<n>
  local loc got input
  if [ "${3#MCP:}" != "$3" ]; then
    IFS=/ read -r o r n <<< "${3#MCP:}"
    input=$(jq -cn --arg o "$o" --arg r "$r" --argjson n "$n" --arg d "$tmp/repo" '{tool_name:"mcp__github__merge_pull_request",tool_input:{owner:$o,repo:$r,pullNumber:$n},cwd:$d}')
  else
    input=$(jq -cn --arg c "$3" --arg d "$tmp/repo" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}')
  fi
  for loc in C en_US.UTF-8; do
    printf '%s' "$input" | GH_STUB_JSON="$4" GH_STUB_FAIL="${5:-0}" PATH="$tmp/bin:$PATH" LC_ALL=$loc \
      /usr/bin/python3 "$hook" 2>"$tmp/err"; got=$?
    if [ "$got" = "$2" ]; then echo "ok   $1 [$loc]"; else echo "FAIL $1 [$loc] (want $2 got $got)"; fail=1; fi
  done
  [ "$2" = 2 ] && [ -s "$tmp/err" ] && echo "     提示：$(head -c 160 "$tmp/err")…"
}
pr() { jq -cn --arg b "$1" --arg h "$2" --arg body "$3" '{number:1501,baseRefName:$b,headRefName:$h,body:$body}'; }
M='gh pr merge'
NOSEC=$'## 改了什么\nx\n\n## Validation\n跑了测试\n\n## Risk\n低\n\n## Rollback\nrevert'
UNCONF=$'## Validation\nok\n\n## 未验证\n- AI 回信归属：测试环境定时扫描在 fund-pay，没跑过\n- 群发进度页\n\n## Risk\n低'
NONE=$'## Validation\nok\n\n## 未验证\n无\n\n## Risk\n低'
CONF=$'## Validation\nok\n\n## 未验证\n- AI 回信归属：没跑过，用户 2026-11-06 确认接受\n  - 补充说明一行\n- 群发进度页：用户 2026-11-06 确认接受\n\n## Risk\n低'

check "1 无小节 → 拦"               2 "$M 1501 --squash --repo OrdoAI/ordo-platform" "$(pr pre feat/x "$NOSEC")"
check "2 列了项没确认 → 拦"          2 "$M 1501 --squash -R OrdoAI/ordo-platform"     "$(pr pre feat/x "$UNCONF")"
check "3 写「无」→ 放行"             0 "$M 1501 --squash -R OrdoAI/ordo-platform"     "$(pr pre feat/x "$NONE")"
check "4 列了项都有确认 → 放行"       0 "$M 1501 --squash -R OrdoAI/ordo-platform"     "$(pr main hotfix/x "$CONF")"
check "5 head=main 同步 PR → 放行"   0 "$M 1650 --merge -R OrdoAI/ordo-platform"      "$(pr pre main "$NOSEC")"
check "6 别的仓库 → 放行"            0 "$M 12 --squash -R somethingcubic/dotfiles"     "$(pr main feat/x "$NOSEC")"
check "按当前目录 remote 识别 → 拦"   2 "$M 1501 --squash"                             "$(pr pre feat/x "$NOSEC")"
check "PR 链接里带仓库 → 拦"         2 "$M https://github.com/OrdoAI/ordo-platform/pull/1501 --squash" "$(pr pre feat/x "$NOSEC")"
check "cd 到别的仓库再合 → 放行"     0 "cd /tmp && $M 3 --squash -R other/repo"        "$(pr pre feat/x "$NOSEC")"
check "发布单 candidate/* → 放行"    0 "$M 1700 -R OrdoAI/ordo-platform"              "$(pr main candidate/20261106-r25 "$NOSEC")"
check "base 不是 pre/main → 放行"    0 "$M 1501 -R OrdoAI/ordo-platform"              "$(pr feat/base feat/x "$NOSEC")"
check "gh 失败 → 拦"                 2 "$M 1501 -R OrdoAI/ordo-platform"              "" 1
check "--disable-auto → 放行"        0 "$M 1501 --disable-auto -R OrdoAI/ordo-platform" "$(pr pre feat/x "$NOSEC")"
NONE2=$'## 未验证\n无（这次改动都在测试环境跑过）\n\n## Risk\n低'
check "「无（说明）」→ 放行"         0 "$M 1501 -R OrdoAI/ordo-platform"              "$(pr pre feat/x "$NONE2")"
check "GitHub MCP 合并无小节 → 拦"   2 "MCP:OrdoAI/ordo-platform/1501"                "$(pr pre feat/x "$NOSEC")"
check "GitHub MCP 合并别的仓库 → 放行" 0 "MCP:somethingcubic/dotfiles/12"             "$(pr main feat/x "$NOSEC")"
check "不是合并命令 → 放行"          0 "gh pr view 1501 -R OrdoAI/ordo-platform"      "$(pr pre feat/x "$NOSEC")"
exit $fail
