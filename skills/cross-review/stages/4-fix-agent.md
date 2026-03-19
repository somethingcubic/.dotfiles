# 阶段 4: 修复 - Agent

执行修复、提交、推送，并通过 status 发布 fix 分支与产物路径。

## 步骤

1. 收到 orchestrator 发来的 `<HIVE ...>` 消息后，读取其中给出的 fix request artifact path
2. 读取 fix request artifact，确认要修的问题和输出路径
3. 创建 fix branch、修改代码、提交、推送
4. 写 fix summary artifact
5. 发布状态

## 完成后发布状态

```bash
hive status-set done "fix ready"           --workspace "$HIVE_WORKSPACE"           --meta cr.stage=4           --meta cr.fix=done           --meta cr.fix.branch=<fix-branch>           --meta cr.artifact=<fix-summary-artifact-path>
```

不要再额外执行 `hive send orchestrator "... fix ready"`；orchestrator 会通过 `hive wait-status` + `hive status-show` 读取 fix branch 和 artifact。只有需要澄清、报告 blocker 或主动请求另一位 agent 做 peer review 时才发 `hive send`。

**注意**：推送前必须确认不是 `main/master`。
