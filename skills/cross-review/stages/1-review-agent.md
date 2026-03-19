# 阶段 1: PR 审查 - Agent

审查 PR，写入 review artifact，然后通过 `hive status-set` 发布完成状态。

## 步骤

1. 收到 orchestrator 发来的 `<HIVE ...>` 消息后，读取其中给出的 review request artifact path
2. 读取 request 里给出的 artifact path 和上下文
3. 读取项目 `REVIEW.md`（如有）
4. 获取 diff
5. 审查代码
6. 写入 review artifact
7. 发布完成状态

---

## 获取 diff

```bash
BASE=$(cat "$HIVE_WORKSPACE/state/base")
git diff "origin/$BASE...HEAD"
```

---

## 发现多少问题

输出所有作者知道后会修复的问题。如果没有值得修复的发现，优先输出“无问题”。

### Bug 判定标准

仅在以下条件全部满足时才标记为 bug：

1. 对准确性、性能、安全性或可维护性有实质影响
2. 问题具体且可操作
3. 修复不要求超出代码库其余部分的严格程度
4. 是本次 commit 引入的（不标记已存在的问题）
5. 作者知道后很可能会修复
6. 不依赖未声明的假设
7. 必须能识别受影响的具体代码位置
8. 明显不是有意为之

---

## 输出格式

将结果写入 request 指定的 review artifact path：

```markdown
## {AGENT} Review

### Findings
(列出问题 或 "No issues found")

### Conclusion
(✅ No issues found 或 🔴/🟠/🟡/🟢 + 最高优先级)
```

完成后发布状态：

```bash
hive status-set done "round 1 review complete"           --workspace "$HIVE_WORKSPACE"           --meta cr.stage=1           --meta cr.review=done           --meta cr.artifact=<review-artifact-path>
```

不要再额外执行 `hive send orchestrator "... complete"`；orchestrator 会通过 `hive wait-status` + `hive status-show` 读取结果。只有需要澄清、blocker 或人工介入时才发 `hive send`。
