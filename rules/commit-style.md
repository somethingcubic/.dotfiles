# Commit Style

## 原子提交（强制）

**一个 commit 一个 concern。** 不允许把多个 P0/P1 修复、不同模块的 bug fix、或新 feature + 重构混在一个 commit 里。

判定标准：commit message 用一句话能讲清楚 → 原子。需要"and"或分号 → 拆。

## Rebase 到目标分支再开工

开新分支前先确认起点：

```bash
git fetch origin
git checkout -b <branch> origin/main   # 不要从 WIP 分支或 stale local main 起
```

如果半路才发现起点错了，rebase 到正确目标 + force-push（需用户授权），不要在错的起点上继续堆 commit。

## Review 拒了不要原样重提

如果 Codex / reviewer 拒掉你的修复，**不允许把同样形状的 patch 再交一遍**。重新从第一性原理推导：

1. 为什么原假说不成立？写出来（不是"换一种说法"，是真的找新证据）
2. 重新枚举可能根因，挑最有证伪测试的那个
3. 实现 + 自测 + 再交

假说收敛纪律（被反问不跳新假说）见 `debugging-discipline` skill。

## 不要 amend 已 push 的 commit

push 之后只允许新 commit。amend / force-push 已 push 的 commit 会破坏 reviewer 的 diff 视图，并且如果 pre-commit hook 失败实际上"上一个 commit 没发生"，amend 会修到更早的 commit 上去——这是数据丢失风险点。

例外：本人独占的 feature 分支、刚 push 还没人 review、显式经用户授权。

## 教训锚点

- 2026-04~05 多个 session 因为把多 bug fix bundle 进单 commit，被 review 退回拆分，浪费一轮。
- 多次出现"被 reviewer 抓住一点 → 把整个 patch 包装一下再交"，本质没改根因，下一轮再被拒。
