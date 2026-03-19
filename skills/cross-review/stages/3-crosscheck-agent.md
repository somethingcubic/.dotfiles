# 阶段 3: 交叉确认 - Agent

与对方 Agent 讨论审查分歧，对每个问题达成共识。

## 步骤

1. 收到 orchestrator 发来的 `<HIVE ...>` 消息后，读取其中给出的 crosscheck request artifact path
2. 读取 request artifact 中的上下文、轮次、目标输出 path
3. 对每个问题做 `Fix` / `Skip` 判断并说明理由
4. 写输出 artifact
5. 发布完成状态

## 输出格式

```markdown
# Cross-Check Analysis

## Issues

### Issue 1: {描述}
- **My judgment**: 🔧 Fix / ⏭️ Skip
- **Reason**: {1-2 句理由}

## Summary Table

| Issue | Judgment | Reason |
| --- | --- | --- |
| ... | 🔧 Fix | ... |
```

## 完成后发布状态

```bash
hive status-set done "crosscheck round complete"           --workspace "$HIVE_WORKSPACE"           --meta cr.stage=3           --meta cr.crosscheck=done           --meta cr.crosscheck.round=<ROUND>           --meta cr.artifact=<crosscheck-artifact-path>
```

不要再额外执行 `hive send orchestrator "... complete"`；orchestrator 会通过 `hive wait-status` + `hive status-show` 读取结果。只有需要继续讨论分歧、报告 blocker 或请求人工裁决时才发 `hive send`。
