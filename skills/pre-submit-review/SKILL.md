---
name: pre-submit-review
description: PR push 之前的红队自审 checklist。当你即将 git push、即将提 PR、即将把改动交给 Codex / reviewer / cross-review 之前必须先跑一遍。把会被 reviewer 抓的问题在自己手上抓掉，省一轮 review。Triggers：用户说"准备提 PR"、"push 一下"、"交给 codex review"、"提交前自查"、"red team 一下"，或检测到 git push / gh pr create 即将执行。
---

# pre-submit-review

**目的**：你的 PR 平均被 Codex 拒 2-3 轮才 LGTM。原因不是 Codex 严苛，是你第一次提交没自审。本 skill 强制把"反派思维"前置。

## 触发时机（自动）

- 即将 `git push origin <branch>`（除非 push 到个人 sandbox 分支）
- 即将 `gh pr create` / `gh pr ready`
- 即将给 Codex / cross-review / 用户做交付
- 准备 mark "implementation complete" / 发 shutdown signal

跑完所有检查项都过了再 push。任何一项失败必须先修。

## Checklist（必须逐项过）

### 1. 改动正确性

- [ ] **跑 verify skill** —— `go build` / `go test` / `go vet` 按改动量分级全过
- [ ] **复现测试存在** —— bug fix 必须有"如果不 fix 就 fail"的回归测试
- [ ] **edge case 覆盖** —— nil / 空数组 / 超时 / 并发竞态 / 错误传播路径都想过
- [ ] **没有 TODO / FIXME / placeholder** —— 见 AGENTS.md "禁止 placeholder"

### 2. Commit 卫生（见 commit-style.md）

- [ ] **原子提交** —— 每个 commit 一个 concern，不允许 "fix bug A + refactor B + add test C" 混合
- [ ] **分支起点正确** —— 不是从 stale main / WIP 分支起的
- [ ] **commit message 讲清"为什么"** —— 不是 "fix bug"，而是 "scheduler 漏判 published 状态导致超时不触发"

### 3. 红队思维（核心 —— 想象自己是要把 PR 拒掉的 reviewer）

逐条问，逐条答（写到 chat 给用户看）：

- **最弱假设是什么？** 我这个 fix 假设了 X 永远成立，X 真的成立吗？grep 过所有 callers 了吗？
- **什么 edge case 会破？** 输入是空 / 巨大 / 并发 / 网络断 / DB 满，哪个会让这个 fix 失效？
- **如果我是 attacker：怎么用这个改动制造数据不一致 / 资源泄漏 / SQL 注入？**
- **如果我是 ops：deploy 这个 commit 后 1 小时内最可能爆的 metric 是什么？**
- **如果我是产品：这个改动对用户感知有什么副作用？我说过吗？**

写出至少 1 个"我自己都不太放心的点"。**不允许全部回答"没问题"**——如果你真的找不到弱点，再读一遍 diff，肯定漏了。

### 4. 文档锚点验证（见 truth-directive.md）

如果 PR 描述 / commit message / 关联 spec 含 `file:line` 锚点：

```bash
# 提取所有 *.go 引用 + 函数名 + env 名，grep 验证存在
grep -oE '[a-zA-Z_/.-]+\.go(:[0-9]+)?' <doc> | sort -u | while read f; do
  [[ -f "${f%:*}" ]] || echo "MISSING: $f"
done
```

任何 MISSING → 修文档或删锚点。**死锚点禁止流到 review**。教训：2026-04-28 凭印象写锚点被下游当 fixture → `~/.claude/postmortems/2026-04-28-runbook-fabricated-anchors.md`。

### 5. 跨服务影响（重型改动专属）

- [ ] **DB schema 变 / proto / API 契约变** → 列出所有 consumer，每个都确认兼容或需要协同改
- [ ] **env / config 变** → 跑 `bash scripts/lint/check-env-consistency.sh`
- [ ] **依赖版本 / Go module 变** → 跑 `go mod tidy && git diff go.sum` 检查无脏改动
- [ ] **canary / preview 部署可验证** —— 不能 merge 完直接 prod 才发现破

### 6. Mermaid / JSON / YAML 渲染验证

如果 PR 描述含 Mermaid / JSON / YAML：

```bash
# JSON 验证
cat <doc> | sed -n '/```json/,/```/p' | sed '1d;$d' | jq . > /dev/null
# Mermaid 用在线 mermaid live 或 mmdc CLI 渲染验证
```

### 7. 写完成 marker（hook 强制校验）

全部检查项通过后，在仓库内执行：

```bash
git rev-parse HEAD > "$(git rev-parse --git-dir)/presubmit-ok"
```

`cmd-guards.sh` hook 会在 `git push` / `gh pr create` 时校验 marker 存在且 sha == 当前 HEAD，不一致直接 deny。改代码后 HEAD 变化 marker 自动失效，需重跑本 skill。紧急绕过（仅限用户明确授权）：命令前缀 `PRESUBMIT_SKIP=1`。

## 输出格式

跑完一轮，给用户：

```
## Pre-Submit Review

✓ verify 全过
✓ commits 原子（5 个 commits，每个独立）
✓ 文档锚点全部验证存在

### 红队找到的弱点（必看）
1. <自己抓出来的弱点 1> —— <已修 / 已加测试 / 决定接受 + 理由>
2. <弱点 2> ——
3. <弱点 3> ——

### 仍然不确定
- <事项> —— 建议 Codex review 时重点看这一点
```

## 反模式

- 不允许 checklist 全打勾但红队部分写"没找到弱点"。Cross-review 不出意外又会拒一次。
- 不允许跳过验证 skill 直接 push，理由"小改动不用测"。小改动也跑轻型 verify，几秒钟的事。
- 不允许把 checklist 当作"输出长报告"。给用户看的应该 ≤ 15 行（response-style.md）。
- 不允许在不熟悉的领域里"假装红队找过了"。不懂的领域明说"红队覆盖不足，需要 reviewer 重点看 X"。
