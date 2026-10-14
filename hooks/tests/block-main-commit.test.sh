#!/bin/bash
# 正负例矩阵：bash hooks/tests/block-main-commit.test.sh
# 建两个临时仓库：M 在 main，F 在 feat。hook 以 M 或 F 作为会话 cwd 运行。
hook="$(cd "$(dirname "$0")/.." && pwd)/block-main-commit.sh"
tmp=$(mktemp -d "$HOME/.bmc-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
M="$tmp/main repo"; F="$tmp/feat"
for d in "$M" "$F"; do mkdir -p "$d"; git -c init.defaultBranch=main init -q "$d" 2>/dev/null || (cd "$d" && git init -q -b main); done
(cd "$F" && git checkout -q -b feat)
mkdir -p "$F/sub"
fail=0

check() { # name expected(deny|allow) session_cwd command
  local json out got
  json=$(jq -cn --arg c "$4" '{tool_input:{command:$c}}')
  out=$(cd "$3" && printf '%s' "$json" | zsh "$hook")
  if printf '%s' "$out" | grep -q '"deny"'; then got=deny; else got=allow; fi
  if [ "$got" = "$2" ]; then echo "ok   $1"; else echo "FAIL $1 (want $2 got $got)"; fail=1; fi
}

# 线性命令：按 git 实际运行的目录判定
check "会话在 main，直接 commit"               deny  "$M" 'git commit -m x'
check "会话在 main，cd 到 feat 再 commit"      allow "$M" "cd $F && git commit -m x"
check "会话在 main，cd 到 feat 子目录"          allow "$M" "cd $F/sub && git add . && git commit -m x"
check "会话在 main，cd 相对路径到 feat"         allow "$M" "cd ../feat && git commit -m x"
check "会话在 feat，cd 到 main 再 commit"      deny  "$F" "cd \"$M\" && git commit -m x"
check "先到 feat 再回 main"                    deny  "$M" "cd $F && cd \"$M\" && git commit -m x"
check "feat 提交后再到 main 提交"              deny  "$M" "cd $F && git commit -m a; cd \"$M\" && git commit -m b"
check "提交说明里写 cd main 不算"              allow "$M" "cd $F && git commit -m \"x; cd $M\""
check "引号包住的 cd 目标"                      allow "$M" "cd \"$F\" && git commit -m x"
check "~ 开头的 cd 目标在 feat"                 allow "$M" "cd ~${F#$HOME} && git commit -m x"
check "会话在 main，cd 到 feat 再 merge"       allow "$M" "cd $F && git merge other"
check "会话在 main 直接 merge"                 deny  "$M" 'git merge other'
check "重定向 2>&1 仍按线性判定"               allow "$M" "cd $F && git commit -m x 2>&1"
check "cd 到不存在目录退回保守判定"            deny  "$M" "cd $tmp/nope; git commit -m x"
# 解析不可靠的形态：退回原来的保守判定（任一候选目录在 main 就拦）
check "子 shell 退回保守"                      deny  "$M" "(cd $F && git commit -m x)"
check "管道里的 cd 不改变目录"                 deny  "$M" "cd $F | true && git commit -m x"
check "后台运行退回保守"                       deny  "$M" "cd $F & git commit -m x"
check "bash -c 退回保守"                       deny  "$M" "bash -c 'cd $F && git commit -m x'"
check "eval 退回保守"                          deny  "$M" "eval 'cd $F' && git commit -m x"
check "GIT_DIR 指向 main 退回保守"             deny  "$M" "cd $F && GIT_DIR=\"$M/.git\" git commit -m x"
check "pushd 退回保守"                         deny  "$M" "pushd $F && git commit -m x"
check "cd - 退回保守"                          deny  "$M" "cd $F && cd - && git commit -m x"
check "命令替换退回保守"                       deny  "$M" "cd \$(echo $F) && git commit -m x"
check "heredoc 退回保守"                       deny  "$M" "cd $F && git commit -F - <<EOF
msg
EOF"
check "保守判定下 feat 会话里 cd main 仍拦"    deny  "$F" "(cd \"$M\" && git commit -m x)"
check "环境变量前缀的 git 仍按目录判定"       deny  "$M" 'FOO=1 git commit -m x'
check "command 前缀的 git 仍按目录判定"        deny  "$M" 'command git commit -m x'
check "env -C 改目录退回保守"                  deny  "$F" "env -C \"$M\" git commit -m x"
check "提交说明里提到 env -C 不算"            allow "$M" "cd $F && git commit -m \"禁用 env -C/--chdir 包裹\""
check "env -i -C 也拦"                         deny  "$F" "env -i -C \"$M\" git commit -m x"
# 其他既有规则不受影响
check "git -C 一律拦"                          deny  "$F" "git -C $F commit -m x"
check "push 到 main 一律拦"                    deny  "$M" "cd $F && git push origin main"
check "push 功能分支放行"                      allow "$M" "cd $F && git push origin feat"
check "非 git 写命令放行"                      allow "$M" 'git status && ls'

exit $fail
