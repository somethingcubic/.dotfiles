# 阶段 2: 判断共识 - Orchestrator

## 禁止操作

- 不要直接操作 tmux

## 概述

分析 Claude 和 GPT 的审查结果，判断是否达成共识。

## 输入

先读取两位 agent 的 published status，拿到 review artifact path：

```bash
CLAUDE_STATUS=$(hive status-show --workspace "$CR_WORKSPACE" --agent claude)
GPT_STATUS=$(hive status-show --workspace "$CR_WORKSPACE" --agent gpt)
```

然后读取各自的 artifact。

## 判断结果

| 结果 | 条件 | 下一阶段 |
| --- | --- | --- |
| `both_ok` | 双方都没发现问题 | → 阶段 5 |
| `same_issues` | 双方发现相同/相似的问题 | → 阶段 4 |
| `divergent` | 结论有分歧 | → 阶段 3 |

## 记录结果

```bash
hive status-set done "stage 2 judged"           --agent orchestrator           --workspace "$CR_WORKSPACE"           --meta cr.stage=2           --meta cr.judge.result=both_ok
```

将 `both_ok` 替换成实际结果，然后进入对应阶段。
