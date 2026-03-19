# 阶段 3: 交叉确认 - Orchestrator

## 禁止操作

- 不要直接操作 tmux

## 概述

让 Claude 和 GPT 讨论分歧，Orchestrator 做消息中继。通信走 `hive send`，产物走 `artifacts/`，完成判定走 `status`。

## 执行

```bash
mkdir -p "$CR_WORKSPACE/artifacts/cross-review/crosscheck"
hive status-set running "stage 3 crosscheck" --agent orchestrator --workspace "$CR_WORKSPACE" --meta cr.stage=3
```

### 轮次循环（最多 5 轮）

每轮都做下面的事：

1. 基于上一轮结果准备两个 request artifact
   - `artifacts/cross-review/crosscheck/claude-round<N>-request.md`
   - `artifacts/cross-review/crosscheck/gpt-round<N>-request.md`
2. 用 `hive send` 发给对应 agent，带上 request artifact path
3. 等待两个 agent 发布完成状态：

```bash
hive wait-status claude -t "$CR_TEAM" -w "$CR_WORKSPACE" --state done --meta cr.stage=3 --meta cr.crosscheck=done --meta cr.crosscheck.round=<N>
hive wait-status gpt -t "$CR_TEAM" -w "$CR_WORKSPACE" --state done --meta cr.stage=3 --meta cr.crosscheck=done --meta cr.crosscheck.round=<N>
```

4. 读取两人的 artifact，判断是否已达成共识

### 输出

最后写汇总 artifact：

```
$CR_WORKSPACE/artifacts/cross-review/crosscheck/summary.md
```

状态建议：

```bash
hive status-set done "stage 3 crosscheck summary ready"           --agent orchestrator           --workspace "$CR_WORKSPACE"           --meta cr.stage=3           --meta cr.crosscheck.summary=$CR_WORKSPACE/artifacts/cross-review/crosscheck/summary.md
```

- 有 Fix 问题 → 阶段 4
- 全部 Skip → 阶段 5
- 有 Deadlock → 阶段 5（标记需人工审查）
