#!/bin/bash
# 正负例矩阵：bash hooks/tests/cmd-guards.test.sh
# 目前只覆盖 Guard 4（tmux kill-server / kill-session 必须用 -S 或 -L 指明一个不是用户主 server 的 server）。
hook="$(cd "$(dirname "$0")/.." && pwd)/cmd-guards.sh"
fail=0

check() { # name expected(deny|allow) command
  local json out got
  json=$(jq -cn --arg c "$3" '{tool_input:{command:$c}}')
  out=$(printf '%s' "$json" | zsh "$hook")
  if printf '%s' "$out" | grep -q '"deny"'; then got=deny; else got=allow; fi
  if [ "$got" = "$2" ]; then echo "ok   $1"; else echo "FAIL $1 (want $2 got $got)"; fail=1; fi
}

# 不指明 server：拦
check "事故原句：只设 TMUX_TMPDIR"             deny  'T=$(cat /tmp/smoke); TMUX_TMPDIR=$T tmux kill-server; rm -rf $T'
check "裸 kill-server"                         deny  'tmux kill-server'
check "绝对路径的 tmux"                         deny  '/opt/homebrew/bin/tmux kill-server'
check "前一段带 -L，后一段不带"                 deny  'tmux -L a ls; tmux kill-server'
check "&& 后的第二条不带"                       deny  'tmux -L x kill-server && tmux kill-server'
check "env -u TMUX 也要求显式指明"              deny  'env -u TMUX tmux kill-server'
check "-f 不是 socket 参数"                      deny  'tmux -f /dev/null kill-server'
check "命令名缩写"                               deny  'tmux kill-ser'
check "Python 列表形式"                          deny  "python3 -c 'import subprocess; subprocess.run([\"tmux\", \"kill-server\"])'"
check "参数写在 kill-server 之后无效"            deny  'tmux kill-server -L x'
check "命令替换里"                               deny  'x=$(tmux kill-server)'
check "反引号里"                                 deny  'x=`tmux kill-server`'
check "sudo 前缀"                                deny  'sudo tmux kill-server'
check "制表符分隔"                               deny  $'tmux\tkill-server'
check "分号后不带空格"                           deny  'ls;tmux kill-server'
check "&& 后不带空格"                            deny  'ls&&tmux kill-server'
check "|| 后不带空格"                            deny  'true||tmux kill-server'
check "花括号后不带空格"                         deny  '{tmux kill-server;}'
check "文本里提到也拦（宁可误拦）"              deny  'grep -n "tmux kill-server" notes.md'
check "反斜杠续行"                               deny  $'tmux \\\n  kill-server'
check "PRESUBMIT_SKIP 前缀不跳过本条"            deny  'PRESUBMIT_SKIP=1 tmux kill-server'

# 指明了 server：放行
check "-L 名字"                                  allow 'tmux -L probe kill-server'
check "-L 紧跟名字"                              allow 'tmux -Lprobe kill-server'
check "-S 路径"                                  allow 'tmux -S /tmp/x/tmux-501/default kill-server'
check "-S 变量"                                  allow 'tmux -S "$SOCK" kill-server'
check "-f 之后再 -L"                             allow 'tmux -f /dev/null -L x kill-server'
check "反斜杠续行带 -L"                          allow $'tmux -L x \\\n  kill-server'
check "合并短参数 -vL"                           allow 'tmux -vL x kill-server'
check "Python 列表带 -L"                         allow "python3 -c 'import subprocess; subprocess.run([\"tmux\", \"-L\", \"x\", \"kill-server\"])'"

# 显式指明的是用户主 server：拦
check "-L default"                               deny  'tmux -L default kill-server'
check "-L 紧跟 default"                          deny  'tmux -Ldefault kill-server'
check "-L 引号里的 default"                      deny  "tmux -L 'default' kill-server"
check "合并短参数 -vL default"                   deny  'tmux -vL default kill-server'
check "-S 主 server 的 socket"                   deny  'tmux -S /private/tmp/tmux-501/default kill-server'
check "-S /tmp 下主 server 的 socket"            deny  'tmux -S /tmp/tmux-501/default kill-server'
check "-S 取自 \$TMUX"                           deny  'tmux -S "${TMUX%%,*}" kill-server'
check "-S 直接用 \$TMUX"                         deny  'tmux -S $TMUX kill-server'
check "Python 列表 -L default"                   deny  "python3 -c 'import subprocess; subprocess.run([\"tmux\", \"-L\", \"default\", \"kill-server\"])'"

# kill-session 同样要求指明非主 server
check "裸 kill-session"                          deny  'tmux kill-session -t thtrial'
check "kill-session 不带 -t"                     deny  'tmux kill-session'
check "kill-session -L default"                  deny  'tmux -L default kill-session -t dev'
check "kill-session 在 && 之后"                  deny  'tmux -L x ls && tmux kill-session -t dev'
check "kill-session 带 -L"                       allow 'tmux -L probe kill-session -t x'
check "kill-session 带 -S"                       allow 'tmux -S "$SOCK" kill-session -t x'

# 名字或路径只是含 default：放行
check "-L 名字以 default 开头"                   allow 'tmux -L default-probe kill-server'
check "-S 变量名以 TMUX_ 开头"                   allow 'tmux -S "$TMUX_SOCK" kill-server'
check "-S 测试目录下名为 default 的 socket"      allow 'tmux -S /tmp/th-x/tmux-501/default kill-server'

# 其他 tmux 命令不受影响
check "kill-window"                              allow 'tmux kill-window -t @11'
check "tmux ls"                                  allow 'tmux ls'
check "只提到 kill-server 没有 tmux"             allow "grep -rn 'kill-server' ."
check "TMUX_TMPDIR 大写不算 tmux 命令"           allow 'echo $TMUX_TMPDIR; ls'
check "文件名里连写的两个词"                     allow 'git add postmortems/2026-10-15-tmux-kill-server-via-TMUX-env.md'
check "路径里的 tmux 目录名"                     allow 'ls /tmp/tmux-501/ && cat notes/kill-server.md'
check "名字里带 tmux 的其他程序"                 allow 'mytmux kill-server'

# Guard 3：push 前的 presubmit-ok marker 按会话目录（JSON 的 .cwd）所在仓库判定。
# Claude Code 以项目目录为进程 cwd 启动 hook，app 建的 worktree 会话里项目目录是主 checkout。
tmp=$(mktemp -d "${TMPDIR:-/tmp}/cg-test.XXXXXX"); trap 'rm -rf "$tmp"' EXIT
M="$tmp/main"; W="$M/.claude/worktrees/wt"
git -c init.defaultBranch=main init -q "$M"
(cd "$M" && git -c user.name=t -c user.email=t@t commit -q --allow-empty -m init && git worktree add -q -b wtfeat "$W")
(cd "$W" && git -c user.name=t -c user.email=t@t commit -q --allow-empty -m wt)
mgit=$(cd "$M" && git rev-parse --absolute-git-dir); wgit=$(cd "$W" && git rev-parse --absolute-git-dir)
mark() { (cd "$1" && git rev-parse HEAD) > "$2/presubmit-ok"; }
pcheck() { # name expected(deny|allow) hook_process_cwd json_cwd command
  local json out got
  json=$(jq -cn --arg c "$5" --arg d "$4" '{tool_input:{command:$c}} + (if $d == "" then {} else {cwd:$d} end)')
  out=$(cd "$3" && printf '%s' "$json" | zsh "$hook")
  if printf '%s' "$out" | grep -q '"deny"'; then got=deny; else got=allow; fi
  if [ "$got" = "$2" ]; then echo "ok   $1"; else echo "FAIL $1 (want $2 got $got)"; fail=1; fi
}
mark "$W" "$wgit"
pcheck "worktree 已审、主 checkout 未审：worktree 会话 push 放行" allow "$M" "$W" 'git push origin wtfeat'
pcheck "worktree 会话相对路径 cd 回未审的主 checkout 再 push"     deny  "$M" "$W" 'cd ../../.. && git push'
pcheck "没有 .cwd 时按进程 cwd（未审的主 checkout）"              deny  "$M" ""   'git push origin wtfeat'
rm -f "$wgit/presubmit-ok"; mark "$M" "$mgit"
pcheck "主 checkout 已审、worktree 未审：worktree 会话 push 拦"   deny  "$M" "$W" 'git push origin wtfeat'
pcheck "worktree 会话 cd 到已审的主 checkout 再 push"            allow "$M" "$W" "cd \"$M\" && git push"
pcheck ".cwd 不存在时退回进程 cwd（已审的主 checkout）"           allow "$M" "$tmp/nope" 'git push origin wtfeat'

exit $fail
