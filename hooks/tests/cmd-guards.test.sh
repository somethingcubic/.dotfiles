#!/bin/bash
# 正负例矩阵：bash hooks/tests/cmd-guards.test.sh
# 目前只覆盖 Guard 4（tmux kill-server 必须用 -S 或 -L 指明 server）。
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

# 其他 tmux 命令不受影响
check "kill-session"                             allow 'tmux kill-session -t thtrial'
check "kill-window"                              allow 'tmux kill-window -t @11'
check "tmux ls"                                  allow 'tmux ls'
check "只提到 kill-server 没有 tmux"             allow "grep -rn 'kill-server' ."
check "TMUX_TMPDIR 大写不算 tmux 命令"           allow 'echo $TMUX_TMPDIR; ls'
check "文件名里连写的两个词"                     allow 'git add postmortems/2026-10-15-tmux-kill-server-via-TMUX-env.md'
check "路径里的 tmux 目录名"                     allow 'ls /tmp/tmux-501/ && cat notes/kill-server.md'
check "名字里带 tmux 的其他程序"                 allow 'mytmux kill-server'

exit $fail
