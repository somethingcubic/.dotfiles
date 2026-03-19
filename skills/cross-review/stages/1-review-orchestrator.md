# 阶段 1: 并行 PR 审查 - Orchestrator

## 前置条件

- 调用方已通过 `hive create --workspace ... --state ...` 初始化 workspace
- `CR_WORKSPACE` / `HIVE_WORKSPACE` 和 `CR_TEAM` 环境变量已设置
- hive team 已创建

## 禁止操作

- 不要重新执行 `hive create`
- 不要直接操作 tmux

## 概述

启动 Claude 和 GPT 并行审查 PR，并通过直接 `<HIVE ...>` 消息 + `status` 管理任务。`cross-review` 作为 workflow skill 由 Hive 显式加载。

## 执行

```bash
export HIVE_WORKSPACE="${HIVE_WORKSPACE:-$CR_WORKSPACE}"
mkdir -p "$CR_WORKSPACE/artifacts/cross-review/requests" "$CR_WORKSPACE/artifacts/cross-review/reviews"

hive status-set running "stage 1 parallel review"           --agent orchestrator           --workspace "$CR_WORKSPACE"           --meta cr.stage=1

MODEL_CLAUDE="${CR_MODEL_CLAUDE:-custom:Claude-Opus-4.6-0}"
MODEL_GPT="${CR_MODEL_GPT:-custom:GPT-5.4-1}"

hive spawn claude -t "$CR_TEAM" -m "$MODEL_CLAUDE" --workflow cross-review \
  -e "HIVE_WORKSPACE=$CR_WORKSPACE" -e "CR_WORKSPACE=$CR_WORKSPACE"
hive spawn gpt -t "$CR_TEAM" -m "$MODEL_GPT" --workflow cross-review \
  -e "HIVE_WORKSPACE=$CR_WORKSPACE" -e "CR_WORKSPACE=$CR_WORKSPACE"
```

## 发送任务

```bash
REPO=$(cat "$CR_WORKSPACE/state/repo")
PR_NUMBER=$(cat "$CR_WORKSPACE/state/pr-number")
BASE=$(cat "$CR_WORKSPACE/state/base")
BRANCH=$(cat "$CR_WORKSPACE/state/branch")

for AGENT in claude gpt; do
  REQUEST="$CR_WORKSPACE/artifacts/cross-review/requests/${AGENT}-review.md"
  RESULT="$CR_WORKSPACE/artifacts/cross-review/reviews/${AGENT}-r1.md"

  cat > "$REQUEST" << EOF
# PR Review Task

You are reviewing PR #$PR_NUMBER in $REPO ($BRANCH → $BASE).

## Instructions
1. Read ~/.factory/skills/cross-review/stages/1-review-agent.md
2. Perform the review independently
3. Write your review artifact to: $RESULT
4. When fully complete, publish:
   hive status-set done "round 1 review complete"              --workspace "$CR_WORKSPACE"              --meta cr.stage=1              --meta cr.review=done              --meta cr.artifact=$RESULT
EOF

  hive send "$AGENT" "Read the attached review request artifact and execute it."             --from orchestrator             --artifact "$REQUEST"             --team "$CR_TEAM"             --workspace "$CR_WORKSPACE"
done
```

## 等待

```bash
hive wait-status claude -t "$CR_TEAM" -w "$CR_WORKSPACE" --state done --meta cr.stage=1 --meta cr.review=done --timeout 600 &
hive wait-status gpt -t "$CR_TEAM" -w "$CR_WORKSPACE" --state done --meta cr.stage=1 --meta cr.review=done --timeout 600 &
wait
```

两个 Agent 都完成后，进入阶段 2。
