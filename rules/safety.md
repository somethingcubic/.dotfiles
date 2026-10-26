---
description: 生产、SSH、配置安全的细则。红线一行式在 AGENTS.md 红线 A，这里只写红线里没有的细节。刻意常驻。
---

# 安全细则（红线见 AGENTS.md 红线 A）

## 生产

- 生产环境包括 prod（8.219.202.238 / ordoai）和 refresh（8.222.139.116 / ordo-refresh / data-center），规则相同。
- 「SSH 只读」指：不在服务器上用 vim、nano、`sed -i`、`echo >`、`cat >`、cp、mv、rm 改业务代码或配置；配置和代码改动只走 git 和正常部署流程。看日志、看进程不受限。
- 生产机上做只读统计一律用流式管道（`zcat f… | grep -c`），不写 /tmp、/dev/shm 临时副本再删。prod-safety hook 拦不住 `zcat … > /tmp/…`。
- 打印日志行前先 `grep -o` 只取需要的字段，或截掉 `?` 之后的查询串（飞书长连接日志的 wss URL 带 access_key）。
- 临时实验开关（`DERIVE_SKIP_TAGS`、`REFRESH_ENABLED`、token limits 等）实验完立即恢复原值。教训：`~/.claude/postmortems/2026-03-30-derive-tags-flag-not-reverted.md`

## SSH

- 发起新 SSH 前先 `ps aux | grep 'ssh.*<host>'` 查残留连接，有就先 kill。新会话开始时检查上次残留的 SSH 和远程进程：会话中断后它们不会自己退出，会把 sshd 打满，所有人都登录不了。教训：`~/.claude/postmortems/2026-03-12-ssh-zombie-batch-insert.md`
- 参数含 `*`、`&`、`!`、`$`、`()` 等元字符且引号嵌套超过 2 层时，改用临时文件或 stdin（`echo "SQL" | ssh host 'mysql ...'`），不内联硬拼。

## 配置与凭据

- 用任何连接配置（SSH、数据库、MQ、Kafka、Redis、API）之前，先从现有 env、配置文件、secrets manager 读取，并多处核对；找不到或核对不了就停下来问，不猜、不编连接串、凭据、host、port。
- 凭据不写进 permissions allow 规则、settings 和脚本，放服务器侧 `~/.my.cnf`、env 或 secrets manager。教训：2026-07-21 settings.json 的 allow 列表内嵌了生产 RDS 密码明文，散布到 7 个备份文件。
- `git -C` 会让分支保护 hook 的目录检测失效，`block-main-commit.sh` 无条件拦截。教训：`~/.claude/postmortems/2026-03-31-git-dash-c-main-push.md`
