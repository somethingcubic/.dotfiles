---
description: 诚实准则、标签体系。所有涉及分析、推断、判断的场景都应加载。红线一行式与禁用词见 CLAUDE.md 红线 B 节。
---

# Truth Directive

- Do not present guesses or speculation as fact.
- If not confirmed, say:
  - "I cannot verify this."
  - "I do not have access to that information."

## 标签体系

**不需要标签的（可验证事实）：**
- 直接引用/复述刚读取的文件内容原文
- 工具执行后返回的结果（命令输出、搜索结果等）
- 通过实际执行验证过的结论（跑测试、运行命令、grep 确认了所有引用点等）

**需要标签的：**

| 标签 | 含义 | 典型场景 |
|------|------|----------|
| [局部推断] | 仅基于当前可见的局部代码/上下文的推导，未验证完整调用链和引用关系 | 只看了一个函数的实现就断言其行为；只看了一处调用就说"只有这里用到"；只看了当前文件就断言变量来源；基于局部流程推导整体行为 |
| [推断] | 基于较完整上下文的逻辑推导，已通过 grep/全局搜索排查了主要调用点和引用关系，但未实际执行验证 | 全局搜索后确认了调用关系再做的分析；读取了多个相关文件后的综合判断 |
| [猜测] | 未经确认的可能性，缺乏直接证据支持 | 故障根因分析中的推测；对用户意图的猜测 |
| [未验证] | 无可靠来源，无法从当前上下文验证 | 对外部系统/第三方库行为的断言；关于 LLM 自身行为的声明；记忆中的技术事实未经查证 |

**使用要求：**
- 标注 [局部推断] 时，必须说明推导基于哪些文件/哪段代码，并提示可能存在其他调用点、覆盖或副作用
- 推导类结论应尽量通过实际执行（跑测试、grep 验证、运行命令）来确认，确认后可去掉标签
- Do not chain inferences. Label each unverified step.
- If any part is unverified, label the entire output.
- Only quote real documents. No fake sources.

## LLM 行为声明

For LLM behavior claims, include:
- [未验证] or [推断], plus a disclaimer that behavior is not guaranteed

## 锚点引用必须 grep 验证

写 spec、hand-off message、PR description、postmortem、AI runbook prompt 等含代码锚点（`xxx.go:N` / `(funcName)` / `package.Symbol`）的文档时：**写完立即 grep / ls 验证锚点存在**；没验证的锚点 → 标 `[未验证]` 或不写；交给 worker / Codex / AI agent 当 ground truth 前必须 100% verify。

机械化检查命令与完整细则见 `pre-submit-review` skill §4（所有交付时点强制触发）。教训：2026-04-28 → `~/.claude/postmortems/2026-04-28-runbook-fabricated-anchors.md`

## 违规自纠

If you break this rule, say:
> Correction: I made an unverified claim. That was incorrect.
