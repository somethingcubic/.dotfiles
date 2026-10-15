#!/bin/bash
# 用法：tmux-send.sh <pane> "<消息>"
# 给另一个 agent（Codex 或 Claude Code）所在的 tmux pane 发一条消息，并确认已经提交。
# 做法：send-keys -l 发原文，sleep 1 后单独发 Enter，再用 capture-pane 确认。
# 只用 send-keys 时长消息会留在输入框里不提交（2026-10-14 三条 review 请求卡住）。
# 输出 SENT（退出码 0）或 UNCONFIRMED（退出码 1）。
# 多个 agent 同时给同一个 pane 发消息时，用 mkdir 锁排队，避免按键交错。
set -u
if [ $# -ne 2 ] || [ -z "$2" ]; then
  echo "用法：tmux-send.sh <pane> \"<消息>\"" >&2
  exit 2
fi
PANE=$1
MSG=$2
LOCK="${TMPDIR:-/tmp}/tmux-send-$(printf '%s' "$PANE" | tr -c 'A-Za-z0-9' '_').lock"
got=
for _ in $(seq 1 600); do
  if mkdir "$LOCK" 2>/dev/null; then got=1; break; fi
  sleep 1
done
if [ -z "$got" ]; then
  echo "等锁超过 600 秒：$LOCK。确认没有别的发送在进行后，删掉这个目录再发" >&2
  exit 1
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT
tmux send-keys -t "$PANE" -l -- "$MSG" || exit 1
sleep 1
tmux send-keys -t "$PANE" Enter || exit 1
sleep 4
# Enter 之后，对方开始处理（Working / esc to interrupt），或者 Codex 的输入框回到空提示，都算已提交。
# 先去掉空行：pane 没写满时 capture-pane 末尾是空行，直接 tail 只能取到空行
if tmux capture-pane -p -t "$PANE" | grep -v '^[[:space:]]*$' | tail -8 | grep -qE "Ask Codex to do anything|[Ee]sc to interrupt|Working"; then
  echo SENT
else
  echo UNCONFIRMED
  exit 1
fi
