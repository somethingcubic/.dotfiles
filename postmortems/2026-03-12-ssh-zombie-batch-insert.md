# 2026-03-12 僵尸 SSH 连接 + 失控批量插入致测试服务器不可用

## 事实

- 大量会话中断后残留的 SSH 进程未终止，变成僵尸连接持续占用测试服务器连接数
- 同期一次批量插入失控：shell 多层引号嵌套导致 SQL 的 `LIMIT` 丢失，预期 100 条实际插入 19,737 条
- 叠加后测试服务器 sshd 打满，SSH 完全不可用，且无人有控制台权限恢复，只能等待自行恢复

## 根因

1. SSH 无超时参数（无 ConnectTimeout / ServerAliveInterval），会话中断后连接不释放
2. 批量写操作未先 `SELECT COUNT(*)` 验证影响行数
3. 密码/参数含元字符时经 本地 shell → SSH → 远程 shell → mysql 多层传递被展开截断

## 沉淀的规则（safety.md / CLAUDE.md 红线 A）

- SSH 并发 ≤ 3；新连接前检查残留；必带 `-o ConnectTimeout=10 -o ServerAliveInterval=5`
- 批量写前必须 `SELECT COUNT(*)` 确认影响行数
- 引号嵌套 >2 层改临时文件或 stdin 管道，禁止内联硬拼
- 2026-07-21 起 `cmd-guards.sh` hook 对 SSH 超时参数与已知 host 并发数机械拦截
