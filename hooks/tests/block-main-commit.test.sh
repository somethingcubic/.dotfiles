#!/bin/bash
# 正负例矩阵：bash hooks/tests/block-main-commit.test.sh
# 建两个临时仓库：M 在 main，F 在 feat；再从 M 建 worktree W（wtfeat 分支）。
# hook 进程 cwd 取 M/F/W；可选第 5 个参数放进 JSON 的 .cwd（Claude Code 的会话目录）。
hook="$(cd "$(dirname "$0")/.." && pwd)/block-main-commit.sh"
tmp=$(mktemp -d "$HOME/.bmc-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
M="$tmp/main repo"; F="$tmp/feat"
for d in "$M" "$F"; do mkdir -p "$d"; git -c init.defaultBranch=main init -q "$d" 2>/dev/null || (cd "$d" && git init -q -b main); done
(cd "$F" && git checkout -q -b feat)
mkdir -p "$F/sub"
W="$M/.claude/worktrees/wt"
(cd "$M" && git -c user.name=t -c user.email=t@t commit -q --allow-empty -m init && git worktree add -q -b wtfeat "$W")
fail=0

check() { # name expected(deny|allow) hook_process_cwd command [json_cwd]
  local json out got
  json=$(jq -cn --arg c "$4" --arg d "${5:-}" '{tool_input:{command:$c}} + (if $d == "" then {} else {cwd:$d} end)')
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
# 只读的连字符子命令不是 merge/commit（merge-base 曾被误拦）
check "会话在 main，git merge-base 放行"       allow "$M" 'git merge-base HEAD origin/main'
check "会话在 main，merge-base 后接判断放行"    allow "$M" 'git merge-base --is-ancestor a b && echo ok'
check "会话在 main，commit-graph 放行"          allow "$M" 'git commit-graph verify'
check "merge 后紧跟分号仍拦"                   deny  "$M" 'git merge; ls'
check "merge 带参数仍拦"                       deny  "$M" 'git merge --no-ff other'
check "merge 在行尾仍拦"                       deny  "$M" 'git merge'
check "merge-base 和 merge 同现仍拦"           deny  "$M" 'git merge-base a b && git merge other'
# 会话目录取 JSON 的 .cwd：Claude Code 以项目目录为进程 cwd 启动 hook，app 建的 worktree 会话里
# 项目目录是主 checkout（main）；会话已在目标目录时 harness 还会去掉多余的 `cd <会话目录> &&`
check "worktree 会话直接 commit"                allow "$M" 'git commit -m x'                      "$W"
check "worktree 会话 heredoc 提交说明"          allow "$M" "git commit -m \"\$(cat <<'EOF'
msg
EOF
)\""                                                                                               "$W"
check "worktree 会话 merge"                     allow "$M" 'git merge other'                      "$W"
check "worktree 会话 cd 主 checkout 再 commit"  deny  "$M" "cd \"$M\" && git commit -m x"         "$W"
check "worktree 会话相对路径 cd 回主 checkout"  deny  "$M" 'cd ../../.. && git commit -m x'       "$W"
check "worktree 会话子 shell 里 cd 主 checkout" deny  "$M" "(cd \"$M\" && git commit -m x)"       "$W"
check "保守判定下相对 cd 按会话目录解析"        deny  "$F" '(cd ../../.. && git commit -m x)'     "$W"
check "会话在 main、进程 cwd 在 feat 仍拦"      deny  "$W" 'git commit -m x'                      "$M"
check ".cwd 不存在时退回进程 cwd"               deny  "$M" 'git commit -m x'                      "$tmp/nope"
# 其他既有规则不受影响
check "git -C 一律拦"                          deny  "$F" "git -C $F commit -m x"
check "push 到 main 一律拦"                    deny  "$M" "cd $F && git push origin main"
check "push 功能分支放行"                      allow "$M" "cd $F && git push origin feat"
check "非 git 写命令放行"                      allow "$M" 'git status && ls'

exit $fail
