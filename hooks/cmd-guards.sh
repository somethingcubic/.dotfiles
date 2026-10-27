#!/bin/zsh
# cmd-guards.sh — PreToolUse(Bash) structural guards for CLAUDE.md red lines
#   Guard 1: ssh must carry ConnectTimeout AND ServerAliveInterval; known-host concurrency <= 6
#   Guard 2: no full-tree `go test ./...` (verify skill tiering red line)
#   Guard 3: git push / gh pr create require pre-submit-review marker
#            (.git/presubmit-ok content == current HEAD sha)
#   Guard 4: tmux kill-server / kill-session must name a server other than the user's main one
# NOTE: never pipe via `echo` — zsh builtin echo interprets backslashes and corrupts
# JSON/commands containing \" (fail-open class found 2026-07-21). Use printf '%s\n'.

INPUT=$(cat) || exit 0
COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[ -z "$COMMAND" ] && exit 0

deny() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$1"
  exit 0
}

# ── Guard 1: SSH hygiene (red line: timeouts mandatory, per-host concurrency <= 6) ──
if printf '%s\n' "$COMMAND" | grep -qE '(^|[;&|[:space:]])ssh[[:space:]]'; then
  if ! printf '%s\n' "$COMMAND" | grep -q 'ConnectTimeout' \
     || ! printf '%s\n' "$COMMAND" | grep -q 'ServerAliveInterval'; then
    deny "❌ SSH 必带超时参数（红线）。请改为: ssh -o ConnectTimeout=10 -o ServerAliveInterval=5 ..."
  fi
  for host in 8.219.202.238 8.222.139.116 47.84.22.38 api.ordo.global tapi.ordo.global ordo-refresh; do
    if printf '%s\n' "$COMMAND" | grep -qF "$host"; then
      N=$(pgrep -f "ssh.*$host" | wc -l | tr -d ' ')
      if [ "$N" -ge 6 ]; then
        deny "❌ host $host 已有 $N 个 ssh 连接（红线 ≤6）。先清残留: ps aux | grep ssh 后 kill"
      fi
    fi
  done
fi

# ── Guard 2: full-tree go test ban (fixed-string match also catches quoted forms) ──
if printf '%s\n' "$COMMAND" | grep -qE '\bgo[[:space:]]+test\b' \
   && printf '%s\n' "$COMMAND" | grep -qF './...' \
   && ! printf '%s\n' "$COMMAND" | grep -qE '^[[:space:]]*FULLTEST=1[[:space:]]'; then
  deny "❌ 禁止全量 go test ./...（验证分级红线）。按 verify skill 档位跑针对性测试；重型场景确需全量且经用户授权: 命令以 FULLTEST=1 前缀开头。"
fi

# ── Guard 4: tmux kill-server / kill-session must name a non-main server (incident 2026-10-15) ──
# Placed before Guard 3, whose PRESUBMIT_SKIP path exits early.
# Span = standalone `tmux` .. standalone `kill-ser` / `kill-ses` within one shell segment; also matches
# ["tmux", "kill-server"]. Both must be whole words, so names like 10-15-tmux-kill-server.md pass.
# Naming the user's main server explicitly counts as not naming one:
#   -L default, -S /tmp/tmux-<uid>/default (or /private/tmp/...), -S built from $TMUX.
TMUX_KILL_SPANS=$(printf '%s\n' "${COMMAND//$'\\\n'/ }" \
  | grep -oE "(^|[[:space:]/\"'(\`;&|{])tmux[\"']?,?([[:space:]][^;&|]*)?[[:space:]\"']kill-se[rs]")
for span in ${(f)TMUX_KILL_SPANS}; do
  if ! printf '%s\n' "$span" | grep -qE "(^|[[:space:]\"'])-[[:alnum:]]*[SL]" \
     || printf '%s\n' "$span" | grep -qE "(^|[[:space:]\"'])-[[:alnum:]]*L[[:space:]\"',]*default([[:space:]\"',]|$)" \
     || printf '%s\n' "$span" | grep -qE "(^|[[:space:]\"'=])(/private)?/tmp/tmux-[0-9]+/default([[:space:]\"',]|$)" \
     || printf '%s\n' "$span" | grep -qE '\$\{?TMUX([^_[:alnum:]]|$)'; then
    deny "❌ tmux kill-server / kill-session 必须用 -S <socket> 或 -L <name> 指明一个不是用户主 server 的 server。不指明时 tmux 先连环境变量 TMUX 指向的 server，TMUX_TMPDIR 会被忽略；-L default、-S /tmp/tmux-<uid>/default、用 \$TMUX 拼出的 -S 都是用户的主 server。agent 在 tmux 里运行时会关掉用户的主 server 或会话（2026-10-15 事故）。Bash 每次调用都是新 shell，上一次的 unset TMUX 不会保留。要关用户的主 server 或会话，请让用户自己执行。"
  fi
done

# ── Guard 3: pre-submit-review marker gate on push / PR create ──
if printf '%s\n' "$COMMAND" | grep -qE '(^|[;&|[:space:]])(git([[:space:]]+-[^[:space:]]+([[:space:]]+[^-[:space:]][^[:space:]]*)?)*[[:space:]]+push\b|gh[[:space:]]+pr[[:space:]]+create\b)'; then
  # escape hatch must be a command PREFIX (env assignment), not a substring anywhere
  printf '%s\n' "$COMMAND" | grep -qE '^[[:space:]]*PRESUBMIT_SKIP=1[[:space:]]' && exit 0

  # Hook cwd is the project dir; the command runs in the session dir (JSON .cwd).
  # In app-made worktree sessions these differ (see block-main-commit.sh, 2026-10-27).
  SESSION_CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
  [ -d "$SESSION_CWD" ] && cd -q "$SESSION_CWD"

  # candidate repos: every `cd <path>` segment, else session cwd
  CD_TARGETS=$(printf '%s\n' "$COMMAND" \
    | grep -oE "(^|[;&|(\"']|[[:space:]])[[:space:]]*cd[[:space:]]+[^;&|]+" \
    | sed -E 's/.*cd[[:space:]]+//' \
    | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^"//;s/"$//')
  typeset -a DIRS
  DIRS=()
  if [ -n "$CD_TARGETS" ]; then
    for t in ${(f)CD_TARGETS}; do
      EXPANDED="${t/#\~/$HOME}"
      [ -d "$EXPANDED" ] && DIRS+=("$EXPANDED")
    done
  fi
  [ ${#DIRS[@]} -eq 0 ] && DIRS=("$PWD")

  for d in "${DIRS[@]}"; do
    GITDIR=$(cd "$d" 2>/dev/null && git rev-parse --git-dir 2>/dev/null)
    [ -z "$GITDIR" ] && continue   # not a repo — nothing to validate here
    HEAD_SHA=$(cd "$d" 2>/dev/null && git rev-parse HEAD 2>/dev/null)
    [ -z "$HEAD_SHA" ] && continue
    MARKER=$(cd "$d" 2>/dev/null && cd "$GITDIR" 2>/dev/null && pwd)/presubmit-ok
    if [ ! -f "$MARKER" ] || [ "$(cat "$MARKER" 2>/dev/null)" != "$HEAD_SHA" ]; then
      deny "❌ push/PR 前必跑 pre-submit-review skill（完成后 git rev-parse HEAD 写入 .git/presubmit-ok）。marker 缺失或与 HEAD 不一致。紧急绕过需用户授权: 命令以 PRESUBMIT_SKIP=1 前缀开头。"
    fi
  done
fi

exit 0
