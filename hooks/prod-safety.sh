#!/bin/zsh
# prod-safety.sh — Global PreToolUse hook (Bash matcher)
# Enforces production safety rules:
#   Rule 0: No direct push to main (PR-only flow)
#   Rule 1: No direct file modifications on remote servers via SSH
#   Rule 2: SSH deploy commands must not pull/checkout a non-main ref on server
#           (local branch state is irrelevant — what runs in prod is determined
#           by server-side git checkout, not local worktree)

INPUT=$(cat) || exit 0
TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null) || exit 0

[ "$TOOL" != "Bash" ] && exit 0

CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[ -z "$CMD" ] && exit 0

CMD_LOWER=$(printf '%s\n' "$CMD" | tr '[:upper:]' '[:lower:]' | tr -s '[:space:]' ' ')

# ══════════════════════════════════════════════════════════
# Rule 0: Block direct push to main — all changes must go through PR
# Match `main` only as a push refspec TARGET (preceded by space or colon,
# followed by space or end) so feature branches whose names merely contain
# main — e.g. `feat/x-main`, `main-menu-fix`, `feat/mainline` — are allowed.
# ══════════════════════════════════════════════════════════
if printf '%s\n' "$CMD_LOWER" | grep -qE 'git([[:space:]]+-[^[:space:]]+([[:space:]]+[^-[:space:]][^[:space:]]*)?)*[[:space:]]+push([^|&;]*[[:space:]:])main([[:space:]]|$)'; then
    cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "🚫 禁止直接 push 到 main 分支。所有变更必须走 PR 流程：切分支 → 提 PR → merge。"
  }
}
EOF
    exit 0
fi

# ── Only care about SSH commands for remaining rules ──
if ! printf '%s\n' "$CMD_LOWER" | grep -qE '(^|[;&|[:space:]])ssh'; then
    exit 0
fi

# ── Known production hosts (prod + refresh/data-center) ──
IS_PROD=false
for host in "8.219.202.238" "api.ordo.global" "agent.ordo.global" "8.222.139.116" "ordo-refresh"; do
    if printf '%s\n' "$CMD" | grep -qF "$host"; then
        IS_PROD=true
        break
    fi
done

# ── Known test hosts ──
IS_TEST=false
for host in "47.84.22.38" "tapi.ordo.global" "tagent.ordo.global"; do
    if printf '%s\n' "$CMD" | grep -qF "$host"; then
        IS_TEST=true
        break
    fi
done

# If neither prod nor test host detected, no opinion
if [ "$IS_PROD" = "false" ] && [ "$IS_TEST" = "false" ]; then
    exit 0
fi

# ══════════════════════════════════════════════════════════
# Rule 1: No direct file modifications on ANY remote server
# ══════════════════════════════════════════════════════════
# Note: redirect patterns use [^0-9]> to avoid matching stderr redirects like 2>/dev/null
WRITE_PATTERN='\bvim?\b|\bnano\b|\bemacs\b|\bsed\b.*-i|\becho\b.*[^0-9]>|\bcat\b.*[^0-9]>|\bprintf\b.*[^0-9]>|\btee\b|\bcp\b|\bmv\b|\brm\s|\bmkdir\b|\btouch\b|\bchmod\b|\bchown\b|\bwget\b.*-O|\bcurl\b.*-o|\btar\b.*-x|\bunzip\b|\bpip install\b|\bapt\b.*install|\byum\b.*install'

# Whitelist: cp .env.xxx .env is part of standard deploy flow
if printf '%s\n' "$CMD_LOWER" | grep -qE 'cp\s+\.env\.[a-z]+\s+\.env'; then
    exit 0
fi

# Whitelist: cp supervisor conf from git repo to /etc/supervisor/ (deploy flow)
if printf '%s\n' "$CMD" | grep -qE 'cp.*/config/.*\.conf.*/etc/supervisor/'; then
    exit 0
fi

# Whitelist: 前端 dist 发布（deploy skill 文档化的 prod 流程）。前端产物是本地
# build + scp 上来的 tarball，落地必然要在服务器上解包并覆盖 dist/ —— 产物本身
# 来自 git 里的源码，不是"绕过 git 改服务器业务代码"。
#
# 收得很窄，四个条件同时成立才放行：
#   (1) 命令里出现 staging 落点 /tmp/ordo-fe-stage-
#   (2) 目标路径含 /ordo_ai/ordo-fe
#   (3) 无 .. 路径穿越
#   (4) 每个绝对路径都必须落在 /tmp/ 或 <repo>/ordo-fe/ 之下
# 仍然拦住：写 /etc、写 ordo-backend、写任何其它业务代码或配置。
if printf '%s\n' "$CMD" | grep -qF '/tmp/ordo-fe-stage-' \
   && printf '%s\n' "$CMD" | grep -qE '/ordo_ai/ordo-fe' \
   && ! printf '%s\n' "$CMD" | grep -qE '\.\./|/\.\.'; then
    # 只取真正的绝对路径 token（行首/空白/引号之后紧跟 /），避免把
    # "$STAGE/assets/." 这类变量展开后的相对片段误判成越界路径。
    FE_BAD_PATH=$(printf '%s\n' "$CMD" \
        | grep -oE '(^|[[:space:]"'"'"'=])/[^[:space:];|&"'"'"'>]*' \
        | sed -E 's/^[[:space:]"'"'"'=]//' \
        | grep -vE '^/tmp(/|$)|^/dev/null$|^/opt/[^/]+/ordo_ai/ordo-fe(/|$)' \
        | head -1)
    if [ -z "$FE_BAD_PATH" ]; then
        exit 0   # 前端 dist 发布 — 允许
    fi
fi

# Whitelist: pure /tmp cleanup. Removing diagnostic artifacts (heap dumps, sampler
# scripts, watch logs) under /tmp is not a business-file change. Allowed ONLY when:
#   (1) rm is present and the command actually targets a /tmp/ path,
#   (2) no other mutating verb (cp/mv/tee/sed/dd/chmod/chown/ln/mkdir/touch/wget/unzip/tar)
#       that could write to or move data onto a real path,
#   (3) no `..` path traversal, and
#   (4) EVERY absolute path is under /tmp/ (bare /tmp and /dev/null allowed for ls/df/redirects).
# Stays BLOCKED: `rm /tmp/x /etc/y`, `rm -rf /tmp/../etc`, `cp /tmp/x /etc/y`, `rm -rf .`.
if printf '%s\n' "$CMD_LOWER" | grep -qE '\brm\b' \
   && printf '%s\n' "$CMD" | grep -qF '/tmp/' \
   && ! printf '%s\n' "$CMD_LOWER" | grep -qE '\bvim?\b|\bnano\b|\bemacs\b|\bsed\b|\btee\b|\bcp\b|\bmv\b|\bdd\b|\bmkdir\b|\btouch\b|\bchmod\b|\bchown\b|\bln\b|\bwget\b|\bunzip\b|\btar\b' \
   && ! printf '%s\n' "$CMD" | grep -qE '\.\./|/\.\.'; then
    OFFENDING_PATH=$(printf '%s\n' "$CMD" | grep -oE '/[^[:space:];|&"'"'"'>]+' | grep -vE '^/tmp(/|$)|^/dev/null$' | head -1)
    if [ -z "$OFFENDING_PATH" ]; then
        exit 0   # pure /tmp rm cleanup — allowed
    fi
fi

if [ "$IS_PROD" = "true" ] && printf '%s\n' "$CMD_LOWER" | grep -qE "$WRITE_PATTERN"; then
    cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "🚫 禁止通过 SSH 直接修改服务器文件。所有变更必须通过 git commit/merge + 正常部署流程上线。"
  }
}
EOF
    exit 0
fi

# ══════════════════════════════════════════════════════════
# Rule 1.5: mysql DML on prod → force human confirmation
# Red line: batch writes require SELECT COUNT(*) verification first.
# "ask" (not deny): legit writes after COUNT are allowed — but must pass a human,
# so wide allowlist globs (ssh *mysql*-e *SELECT*) can never auto-approve a write.
# ══════════════════════════════════════════════════════════
if [ "$IS_PROD" = "true" ] && printf '%s\n' "$CMD_LOWER" | grep -qE '\bmysql\b' \
   && printf '%s\n' "$CMD_LOWER" | grep -qE '\b(update|delete|insert|replace|alter|drop|truncate)\b'; then
    cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "ask",
    "permissionDecisionReason": "⚠️ 生产 mysql 疑似 DML。红线：批量写前必须先 SELECT COUNT(*) 确认影响行数。确认已 COUNT 且行数符合预期后再批准。"
  }
}
EOF
    exit 0
fi

# ══════════════════════════════════════════════════════════
# Rule 2: Production deploy must NOT pull/checkout a non-main ref on server
# ══════════════════════════════════════════════════════════
# Replaces former local-branch check. Local worktree state is unrelated to what
# runs in prod — server determines that via its own checkout. So we instead
# inspect the SSH command for any explicit `git checkout/switch/pull origin <ref>`
# and deny if <ref> is not main/master/-/flag. Commands without git ref ops are
# allowed (trust server's prior `git pull origin main`; rely on GitHub branch
# protection + Rule 0 to keep main clean).
if [ "$IS_PROD" = "true" ]; then
    # Note: `start` (without restart) only resumes STOPPED services with existing binary,
    # and any new-binary path is already blocked by Rule 1 (cp/scp/write patterns).
    # So `start` alone is safe for ops (e.g. restoring services after reboot) and NOT a deploy trigger.
    DEPLOY_PATTERN='supervisorctl[[:space:]]+(restart|reload|update)|systemctl[[:space:]]+(restart|reload)|service[[:space:]]+[^[:space:]]+[[:space:]]+(restart|reload)|\bgo[[:space:]]+build\b|deploy|make[[:space:]]+(deploy|release|build)'

    if printf '%s\n' "$CMD_LOWER" | grep -qE "$DEPLOY_PATTERN"; then
        # Extract the last token of any `git checkout|switch|pull origin <ref>` occurrence in the SSH command.
        BAD_REF=""
        REFS=$(printf '%s\n' "$CMD" | grep -oE 'git[[:space:]]+(checkout|switch)[[:space:]]+[^[:space:]&;|]+|git[[:space:]]+pull[[:space:]]+origin[[:space:]]+[^[:space:]&;|]+' | awk '{print $NF}')
        for ref in $REFS; do
            # Allow main/master/-(prev branch shortcut)/flags starting with -
            case "$ref" in
                main|master|-) continue ;;
                -*) continue ;;
                *) BAD_REF="$ref"; break ;;
            esac
        done

        if [ -n "$BAD_REF" ]; then
            cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "🚫 生产部署 SSH 命令引用了非 main 的 git ref: \`$BAD_REF\`。生产只允许部署 main / master 分支。"
  }
}
EOF
            exit 0
        fi
    fi
fi
