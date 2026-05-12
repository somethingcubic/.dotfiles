---
description: 生产安全、SSH安全、配置安全规则。涉及部署、SSH、数据库、服务器操作时加载。
globs: ["*.sh", "deploy/**", "scripts/**", "*.sql"]
---

# Production Safety (Mandatory)

- **所有代码变更必须走 PR**：禁止直接 commit + push 到 main 分支。所有变更必须切分支 → 提 PR → review → merge。没有例外。
- **禁止使用 `git -C` 执行 git 操作**：`git -C <path>` 会改变工作目录上下文，导致本地 hooks（如 `block-main-commit.sh`）的分支检测失效，绕过分支保护。所有 git 操作必须在仓库目录内用 `cd` 切换后执行，或使用不带 `-C` 的命令。教训：2026-03-31 用 `git -C` 直接推了 3 个 commit 到 main，hook 未拦截，被迫提 revert PR。
- **生产部署只允许 main 分支**：任何涉及生产环境的部署操作（supervisorctl restart、服务重启、二进制替换等），必须先确认当前分支是 `main`。非 main 分支一律拒绝部署到生产环境，测试环境不受此限制。
- **生产环境范围**：prod 服务器（8.219.202.238 / ordoai）和 refresh 服务器（8.222.139.116 / ordo-refresh / data-center）均属于生产环境，适用相同的安全规则。
- **禁止直接修改服务器文件**：所有配置变更和代码变更必须通过 git commit / merge 完成，然后通过正常部署流程上线。禁止通过 SSH 直接在服务器上编辑、创建、删除业务代码或配置文件（vim/nano/sed -i/echo >/cat >/cp/mv/rm 等写操作）。临时排查产生的日志查看、进程查看等只读操作不受限制。
- **临时实验开关必须立即复原**：为测试/调试/验证目的临时修改的任何开关或配置（如 `DERIVE_SKIP_TAGS`、`REFRESH_ENABLED`、token limits 等），实验完毕后**必须立即恢复原值**。不允许"先改了后面再说"。教训：2026-03-30 临时开启 tags 忘记关闭，导致 57,000 次不必要的 LLM 调用。

# SSH & Remote Operation Safety (Mandatory)

- **SSH 并发控制**：同一台服务器的 SSH 连接不得超过 3 个。发起新 SSH 命令前，先用 `ps aux | grep 'ssh.*<host>'` 检查残留连接，有则先 kill 再连。所有 SSH 命令必须设置超时：`ssh -o ConnectTimeout=10 -o ServerAliveInterval=5`。
- **后台任务清理**：新会话开始时，检查是否有上次残留的 SSH/远程进程。会话中断后这些进程不会自动终止，会变成僵尸进程持续占用服务器连接，可导致 sshd 打满、所有人无法登录。
- **批量操作前验证**：任何批量创建/插入/更新操作，必须先用 `SELECT COUNT(*)` 确认影响行数，确认符合预期后再执行。禁止未经验证直接执行可能影响大量数据的写操作。
- **Shell 特殊字符多层转义**：密码或参数含 `*`、`&`、`!`、`$`、`()` 等元字符时，经过本地 shell → SSH → 远程 shell → mysql 多层传递极易被展开或截断。当引号嵌套超过 2 层时，必须改用临时文件或 stdin 管道方案（如 `echo "SQL" | ssh host 'mysql ...'`），禁止内联硬拼。
- **教训**：2026-03-12 因大量僵尸 SSH 连接 + 失控的批量插入（shell 引号导致 LIMIT 丢失，100 条变 19,737 条），测试服务器 SSH 完全不可用且无人有控制台权限恢复，只能等待自行恢复。

# Configuration Safety (Mandatory)

- Before using ANY configuration (including but not limited to SSH connections, database connections, MQ connections, Kafka connections, Redis, API endpoints, etc.):
  1. First check and read configuration from existing environment (env files, config files, secrets managers, etc.)
  2. Verify the configuration is correct through multiple checks before execution
  3. **NEVER guess or fabricate connection strings, credentials, hosts, ports, or any connection parameters**
  4. If configuration cannot be found or verified, stop and ask the user to provide or confirm the configuration
- Violation of this rule may cause serious security incidents or data corruption.
