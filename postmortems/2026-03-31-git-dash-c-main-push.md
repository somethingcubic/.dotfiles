# 2026-03-31 `git -C` 绕过分支保护 hook 直推 3 个 commit 到 main

## 事实

- 使用 `git -C <path>` 形式执行 git 操作，本地 `block-main-commit.sh` hook 的分支检测失效（hook 在自身 cwd 取分支，`-C` 目标仓库不在检测范围；且 `git\s+commit` 相邻正则不匹配 `git -C /repo commit`）
- 3 个 commit 被直接推到 main，被迫提 revert PR

## 根因

hook 的命令解析假设 git 子命令紧跟 `git`，未覆盖 `-C` 全局参数形态；修复当时只落在 prose 红线（"禁用 git -C"），hook 本体未堵。

## 沉淀的规则与结构化修复

- CLAUDE.md 红线 A / safety.md：禁用 `git -C`，git 操作必须 `cd` 进仓库执行
- 2026-07-21：`block-main-commit.sh` 增加 `git -C`（含引号形态）与 `--git-dir/--work-tree` 无条件 deny + commit/push/merge 正则容错（`-c k=v` option-arg）+ 多 cd 候选分支检测 + unborn HEAD 修复
- 2026-07-21 同日对抗验收再发现一类 fail-open：zsh 内建 `echo "$INPUT" | jq` 会解释反斜杠，命令含 `\"` 嵌套转义时 JSON 被破坏 → jq 失败 → hook 静默放行。三个安全 hook 全部改用 `printf '%s\n'` 管道并以含反斜杠载荷回归通过。教训：hook 里禁止用 echo 传不可信字符串
