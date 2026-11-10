#!/bin/bash
# bash hooks/tests/zsh-word-split-guard.test.sh ；每个用例在 C 和 UTF-8 下各跑一次（桌面端调 hook 时是 C）。
# HOOK=<别的文件> 可以换掉被测 hook（变异：换成空脚本时「拦」的用例必须 FAIL）。
hook="${HOOK:-$(cd "$(dirname "$0")/.." && pwd)/zsh-word-split-guard.py}"
fail=0
check() { # name expected_exit json
  local loc got
  for loc in C en_US.UTF-8; do
    printf '%s' "$3" | LC_ALL=$loc /usr/bin/python3 "$hook" 2>/dev/null; got=$?
    if [ "$got" = "$2" ]; then echo "ok   $1 [$loc]"; else echo "FAIL $1 [$loc] (want $2 got $got)"; fail=1; fi
  done
}
bash_cmd() { jq -cn --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}'; }
block() { check "拦 $1" 2 "$(bash_cmd "$2")"; }
allow() { check "放 $1" 0 "$(bash_cmd "$2")"; }
T='-o ConnectTimeout=10 -o ServerAliveInterval=5'
NL=$'\n'

# ── 拦 ──
block "11-10 原例 ssh \$O"            "O=\"$T\"; ssh \$O 8.219.202.238 uptime"
block "完成标准里的例子"               'O="-o A=1 -o B=2"; ssh $O x'
block "\${O} 写法"                    "O=\"$T\"; ssh \${O} host uptime"
block "单引号赋值"                     "O='$T'; ssh \$O host uptime"
block "export 赋值后用"                "export O=\"$T\" && ssh \$O host uptime"
block "后台监控循环"                   "O=\"$T\"; while true; do ssh \$O host 'uptime' >> /tmp/m.log 2>&1; sleep 60; done"
block "分行写"                         "O=\"$T\"${NL}ssh \$O host uptime"
block "双引号里的 \$(…) 里"            "O=\"$T\"; R=\"\$(ssh \$O host uptime)\"; echo \"\$R\""
block "if 分支里"                      "O=\"$T\"; if true; then ssh \$O host uptime; fi"
block "timeout 包着"                   "O=\"$T\"; timeout 20 ssh \$O host uptime"
block "curl 选项串"                    'H="-H X-A:1 -H X-B:2"; curl -s $H https://example.com'
block "lessons 原例 set -- \$st"        'st="a b c"; set -- $st; echo $1'
block "变量当命令名"                   'CMD="python3 -m http.server"; $CMD 8000'
block "for … in 列表"                  'HOSTS="a b c"; for h in $HOSTS; do echo $h; done'
block "+= 追加后用"                    "O=-v; O+=\" $T\"; ssh \$O host"
block "ssh -p 之后"                    "O=\"$T\"; ssh -p 22 \$O host uptime"

# ── 放 ──
allow "加引号 \"\$O\""                 "O=\"$T\"; ssh \"\$O\" host uptime"
allow "加引号 \"\${O}\""               "O=\"$T\"; ssh \"\${O}\" host uptime"
allow "bash -c 单引号里"               "bash -c 'O=\"$T\"; ssh \$O host uptime'"
allow "bash -c 双引号里转义"            "bash -c \"O='$T'; ssh \\\$O host uptime\""
allow "单值变量 ssh \$HOST"             "HOST=prod; ssh $T \$HOST uptime"
allow "没赋值的变量"                    "ssh $T \$HOST uptime"
allow "数组 \"\${O[@]}\""                "O=($T); ssh \"\${O[@]}\" host uptime"
allow "数组不加引号（zsh 会展开成多个）" "O=($T); ssh \$O host uptime"
allow "zsh 显式拆分 \${=O}"             "O=\"$T\"; ssh \${=O} host uptime"
allow "写进 #!/bin/bash 脚本"           "cat > /tmp/m.sh <<'EOF'${NL}#!/bin/bash${NL}O=\"$T\"${NL}ssh \$O host uptime${NL}EOF${NL}bash /tmp/m.sh"
allow "喂给 bash 的 heredoc"            "bash <<'EOF'${NL}O=\"$T\"${NL}ssh \$O host uptime${NL}EOF"
allow "又赋成单值"                      "O=\"$T\"; O=-v; ssh \$O host"
allow "只给一条命令的前缀赋值"          "O=\"$T\" env | grep -c O; ssh $T \$O host"
allow "赋值右边"                        "O=\"$T\"; P=\$O; ssh $T host"
allow "[[ ]] 和 [ ]"                    "O=\"$T\"; [[ -n \$O ]] && [ -n \$O ] && echo ok"
allow "echo"                            'MSG="hello world"; echo $MSG'
allow "带空格的路径"                    'D="$HOME/Library/Application Support/Claude"; ls $D/side-session-notes'
allow "ssh 远程命令部分"                "CMD=\"tail -n 5 /var/log/x\"; ssh $T host \$CMD"
allow "bash -c 的那一个参数"            'S="cd /tmp && ls"; bash -c $S'
allow "值来自 \$(…)（空格在命令替换里）" "X=\$(date +%s); ssh $T \$X uptime"
check "放 非 Bash 工具" 0 "$(jq -cn '{tool_name:"Read",tool_input:{file_path:"/tmp/x"}}')"
check "放 JSON 坏了"    0 'not json'
exit $fail
