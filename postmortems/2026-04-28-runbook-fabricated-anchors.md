# 2026-04-28 飞书警报 AI runbook 写入不存在的代码锚点

## 事实

- 写 spec 时凭印象写入 `engageKillSwitch` / `scalar.go` / `cache.go` / `reconciler.go` 等**不存在**的代码锚点
- 该 spec 被传给 worker 当 lockdown fixture 使用，Codex 第 2 轮 review 才抓到

## 根因

含代码锚点的文档生成后未做机械化存在性验证，凭印象的锚点被下游当 ground truth。

## 风险模式（bug 链放大）

下游 worker 把死链照搬进生产代码；AI agent 拿到死链 prompt 走 dead-end；lockdown 测试以错误锚点为 fixture 把错固化。

## 沉淀的规则

- `truth-directive.md`：文档内代码锚点写完必须 grep/ls 验证存在，未验证标 [未验证]
- `pre-submit-review` skill §4：交付前对文档锚点做机械化提取 + 逐一验证，死锚点禁止流到 review
