# Postmortem: 子 agent 关掉了用户的主 tmux server，滚屏存档被空存档覆盖

**日期**: 2026-10-15
**项目**: 本机开发环境；触发方是 taskhub（`~/Documents/Projects/taskhub`）的测试工作
**严重程度**: 中。没有生产影响；本机 19 个正在运行的 agent 会话（12 个 Claude Code、7 个 Codex）被中断，各 pane 的终端滚屏文字丢失且无法恢复

## 时间线（+08:00）

| 时间 | 事件 | 证据 |
|---|---|---|
| 10-14 20:46 | taskhub 的探针用 `tmux -L probe` 起了一个 server，之后一直没关 | PID 45429 的启动时间 |
| 10-15 00:08–00:11 | 子 agent 直接在用户主 server 上建、关测试会话 `thtrial`、`thx` | 会话记录 16:07–16:11Z 的 Bash 调用 |
| 00:10:02 | continuum 最后一次正常保存（`dev` 会话 20 个 pane） | `~/.tmux/resurrect/tmux_resurrect_20261015T001002.txt` |
| 00:14:38 | 子 agent 冒烟测试：`export TMUX_TMPDIR=$T ...; unset TMUX; bin/task new demo`，在临时目录起了测试 server `tt`（PID 51198） | 会话记录；51198 的环境变量 `TMUX_TMPDIR=.../tmp.ebBxjDrW2d` |
| 00:15:57 | 同一个子 agent 发起新的一次 Bash 调用：`TMUX_TMPDIR=$T tmux kill-server; rm -rf $T; python3 -m unittest ...` | 会话记录 |
| 00:15:58 | 主 server 退出。这条命令返回 exit 137；12 个 Claude 会话记录在同一秒停止写入，3 个 Codex 会话记录在 00:16:58 停止 | 会话记录文件的修改时间 |
| 00:26:03 | launchd 任务 `com.tmux.resurrect-save` 在没有 server 时运行 save.sh：写出 0 字节存档，把 `last` 指向它，并用空归档覆盖了 `pane_contents.tar.gz`。之后每 15 分钟重复一次 | `~/Library/Logs/tmux-resurrect-save.log` 里的 `no server running` |
| 08:40:14 | 用户执行 `tmux`，起了新 server，没有自动恢复 | zsh history |
| 08:41:08 | launchd 保存了只有 1 个窗口的新 server，`last` 指向它，滚屏归档再次被覆盖 | 132 字节的存档 |
| 08:46 起 | 排查。从会话记录里找到 kill-server 命令；用两个隔离 server 实测 `TMUX` 与 `TMUX_TMPDIR` 的优先级 | 本次会话 |
| 09:20 | 用 00:10:02 的存档恢复了布局：10 个窗口、20 个 pane，编号和目录逐个比对一致 | `tmux list-panes` 与存档的 diff |
| 10:36 起 | 关掉残留的 `tt` 和 probe server；在当前 server 上重新打开 continuum 自动保存；合并 dotfiles PR #8（hook 拦截不指明 server 的 kill-server） | 本次会话 |
| 10:48 | launchd 保存任务改为没有 server 就跳过，重新打开 | 本次会话 |
| 10:50 起 | 合并 dotfiles PR #9（红线 A 加一条）；taskhub 测试改为用 `-S` 关 server | 本次会话 |

子 agent 的位置：Claude 会话 `f1854308-af74-44d1-866a-e842dc70890c`（`~/Documents/Projects`，即主 server 中 `dev` 的第 10 个窗口），workflow `wf_ea1f3e44`，子 agent `a0ba9e9c29ca59664`。

## 根因分析

- **表面原因**：子 agent 用 `TMUX_TMPDIR=$T tmux kill-server` 关测试 server。tmux 在不带 `-S`/`-L` 时先读环境变量 `TMUX`（当前所在 server 的 socket），有值就连它，`TMUX_TMPDIR` 被忽略。子 agent 运行在主 server 的 pane 里，`TMUX` 指向主 server，所以关掉的是主 server，子 agent 自己也一起被关。已实测：同时设置 `TMUX=A` 和 `TMUX_TMPDIR=B` 时 tmux 连 A；去掉 `TMUX` 后才连 B。
- **根本原因**：
  1. 子 agent 以为 00:14:38 那次调用里的 `unset TMUX` 还有效。Claude Code 的 Bash 工具每次调用都是新 shell，`export` 和 `unset` 不会保留到下一次。
  2. 关 server 时没有用 `-S <socket>` 指明目标，选择哪个 server 完全取决于环境变量。
- **为什么损失扩大到滚屏无法恢复**：
  1. launchd 保存任务在没有 server 时照样保存。resurrect 只要新存档和 `last` 内容不同，就把 `last` 指向新存档，所以 0 字节存档成了 `last`。滚屏归档只有一个文件，每次保存都整体覆盖，于是被空内容覆盖。
  2. 残留的 `tt` 和 probe server 让 continuum 判定"已有别的 tmux 在运行"，在新 server 上跳过了自动恢复，也没有打开自动保存。[推断：依据 `tmux-continuum/scripts/helpers.sh` 的 `another_tmux_server_running_on_startup` 和当时的进程列表；当前 server 的 status-right 里确实没有保存脚本]
- **系统性因素**：
  1. agent 的测试直接在用户正在使用的 tmux server 上运行（建 `thtrial`、`thx` 会话），测试环境和用户环境没有隔离。
  2. 测试 server 的创建和关闭分在两次 Bash 调用里，第二次调用没有第一次的环境。kill-server 失败后紧接着 `rm -rf $T` 删掉了 socket，测试 server 变成连不上的残留进程。
  3. 备份链路的两个保存来源（continuum 和 launchd）都会改 `last`；launchd 那一路没有"源不存在就跳过"的判断。滚屏只有一份归档，没有历史版本，本机也没有 Time Machine 本地快照。

## 教训

1. **关 tmux server 必须用 `-S <socket>` 或 `-L <name>` 指明目标，不依赖 `TMUX_TMPDIR` 或之前调用里的 `unset TMUX`。**
   - 适用场景：agent 在 tmux 里运行测试、冒烟脚本，或任何会调用 kill-server、kill-session 的代码。
   - 违反后果：关掉用户的主 server，上面所有 agent 会话一起中断。
2. **定时保存任务在源不存在或读取失败时必须跳过，不能用空结果覆盖"最近一次"的指针或唯一的归档。**
   - 适用场景：任何定时备份、快照、导出脚本。
   - 违反后果：事故发生后，唯一可用的副本被后续的空保存覆盖。
3. **测试创建的临时 server 要在同一次调用里建和关，用唯一的 `-L` 名字或显式 socket，结束时核对没有残留进程。**
   - 适用场景：需要独立 tmux、数据库或其他常驻进程的测试。
   - 违反后果：残留进程无人回收，还会改变其他工具的判断（这次让 continuum 跳过了自动恢复）。

## 行动项

- [x] 用 00:10:02 存档恢复 `dev` 会话布局，逐个 pane 核对编号和目录（10-15 09:20）
- [x] 关掉残留的测试 server `tt`（PID 51198）和 `tmux -L probe`
- [x] launchd 任务 `com.tmux.resurrect-save` 改为先跑 `tmux has-session`，没有 server 就退出，然后重新打开。没有停用它，因为 continuum 只在有终端连着 tmux 时保存（已实测：没连时状态栏命令 3 秒内运行 0 次，连上后 4 秒内运行 6 次），agent 在后台跑时只能靠这个任务存档。验证：没有 server 时不写存档、不动滚屏归档；有 server 时手动触发一次，归档包含 20 个 pane，退出码 0
- [x] 在当前 server 上重新打开 continuum 自动保存
- [x] dotfiles PR #8：`hooks/cmd-guards.sh` 的 Guard 4 拦截不带 `-S`/`-L` 的 kill-server；新增 `hooks/tests/cmd-guards.test.sh`（26 条正负例，换成旧 hook 时 13 条拦截用例全部失败）
- [x] dotfiles PR #9：共用的 `agents/AGENTS.md`（即 CLAUDE.md）红线 A 加一条，关 tmux server 必带 `-S` 或 `-L`，覆盖不运行 hook 的 Codex
- [x] taskhub `tests/test_task.py` 的 tearDown 改为 `tmux -S <socket>` 关 server，不再依赖从环境里去掉 `TMUX`。验证：让 `TMUX` 指向一个诱饵 server 跑全部 18 条测试，诱饵 server 存活，测试结束后没有残留的测试 server。18 条里有 4 条失败，换回原写法失败的是同样 4 条，是 taskhub 原有问题，与本次改动无关
- [ ] 滚屏归档只有一份，可以加 resurrect 的 post-save 钩子保留带时间戳的副本（打磨项，待用户确认）

## Hook 的已知限制

- 用变量间接调用 tmux，或在脚本、测试文件里调用 kill-server，hook 看不到，因为它只检查 Bash 命令的文字。
- 命令文字里出现这两个词（例如 grep 的参数）也会被拦，宁可误拦。
- Codex 不运行这些 hook。
