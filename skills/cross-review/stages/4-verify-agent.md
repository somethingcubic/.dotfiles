# 阶段 4: 验证 - Agent

验证修复是否正确。

## 步骤

1. 收到 orchestrator 发来的 `<HIVE ...>` 消息后，读取其中给出的 verify request artifact path
2. 读取 verify request artifact，拿到 fix branch 和 fix summary artifact
3. 查看修复 diff
4. 验证代码
5. 写 verify artifact
6. 发布状态

## 查看修复

```bash
git fetch origin <fix-branch>
BASE=$(cat "$HIVE_WORKSPACE/state/base")
git diff "origin/$BASE...origin/<fix-branch>"
```

## 输出要求

verify artifact 第一行必须是 `PASS` 或 `FAIL`。

完成后发布状态：

```bash
hive status-set done "verify complete"           --workspace "$HIVE_WORKSPACE"           --meta cr.stage=4           --meta cr.verify=pass           --meta cr.artifact=<verify-artifact-path>
```

若结论为 FAIL，把 `pass` 改成 `fail`。

不要再额外执行 `hive send orchestrator "... verify complete"`；orchestrator 会通过 `hive wait-status` + `hive status-show` 读取结果。只有需要澄清失败原因、报告 blocker 或请求额外人工判断时才发 `hive send`。
