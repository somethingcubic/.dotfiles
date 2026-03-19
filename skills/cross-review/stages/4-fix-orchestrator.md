# 阶段 4: 修复验证 - Orchestrator

## 禁止操作

- 不要直接操作 tmux

## 概述

协调 Claude 修复和 GPT 验证，最多 5 轮。通信仍然走直接 `<HIVE ...>` 消息 + `status`。

## 执行

```bash
mkdir -p "$CR_WORKSPACE/artifacts/cross-review/fix" "$CR_WORKSPACE/artifacts/cross-review/verify"
hive status-set running "stage 4 fix/verify" --agent orchestrator --workspace "$CR_WORKSPACE" --meta cr.stage=4 --meta cr.fix.round=1
```

## Claude 修复

1. 写 fix request artifact，带上需要修复的问题和目标输出路径
2. 发送：

```bash
hive send claude "Read the attached fix request artifact and implement it."           --from orchestrator           --artifact <fix-request-artifact>           -t "$CR_TEAM" -w "$CR_WORKSPACE"
```

3. 等待 Claude：

```bash
hive wait-status claude -t "$CR_TEAM" -w "$CR_WORKSPACE" --state done --meta cr.stage=4 --meta cr.fix=done --timeout 600
```

## GPT 验证

1. 从 Claude 的 status 里读取 `cr.fix.branch` 和 `cr.artifact`
2. 写 verify request artifact
3. 发送给 GPT
4. 等待 GPT：

```bash
hive wait-status gpt -t "$CR_TEAM" -w "$CR_WORKSPACE" --state done --meta cr.stage=4 --timeout 300
```

5. 读取 GPT 的 `cr.verify` 元数据：
   - `pass` → 阶段 5
   - `fail` 且轮数 < 5 → 下一轮修复
   - `fail` 且轮数 >= 5 → 阶段 5（标记未完成）
