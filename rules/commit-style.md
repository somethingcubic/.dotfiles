# Commit Style

- **原子提交**：一个 commit 一个 concern，不把多个修复、不同模块的改动、新功能加重构混在一起。commit message 一句话讲不清（要用「和」或分号）就拆。
- **从目标分支起**：开新分支前 `git fetch origin && git checkout -b <branch> origin/<base>`，不从 WIP 分支或过期的本地 main 起。半路发现起点错了，rebase 到正确目标再 force-push（要用户授权），不在错的起点上继续堆 commit。
- **review 拒了不原样重提**：先写出原假说为什么不成立（找新证据，不是换个说法），重新列可能的根因，挑最容易证伪的那个，实现、自测后再交。被反问时不跳新假说，见 `debugging-discipline` skill。
- **不 amend 已 push 的 commit**：push 之后只加新 commit。amend 会破坏 reviewer 的 diff 视图；pre-commit hook 失败时「上一个 commit」其实没发生，amend 会改到更早的 commit 上。例外：本人独占的分支、刚 push 还没人 review、用户明确授权。
