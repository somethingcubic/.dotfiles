---
name: verify
description: 按改动体量分级执行 build / test / vet / lint 验证。当用户说"验证一下"、"verify"、"看下能不能编过"、"跑一下测试"、或代码改完准备提交前主动自验时使用。Go / TypeScript 都覆盖。本 skill 拒绝跑全量 go test ./...（违反验证开销分级），按改动量自动选合适层级。
---

# verify

代码改完不验证就交付 = 把锅甩给 review。本 skill 是"按改动量匹配验证深度"的执行器。

## 改动量判定

先确认现在是哪一档（本表是分级验证的唯一源）：

| 档位 | 触发条件 | 验证策略 |
|---|---|---|
| **轻型** | <20 行 / 单常量 / env 数值 / 字符串改 | 单 package `go build` + 目标 `go test -run` |
| **轻型 env-only** | 只改 .env / 配置 / 环境变量 | `bash scripts/lint/check-env-consistency.sh`（如存在） |
| **中型** | <150 行 / 单文件状态机 / 单模块改 | 针对性 package 回归 + env 校验 |
| **重型** | 多文件 / 跨服务 / 并发 / 契约变更 | 全量 regression + `make verify`（如存在） + canary |

判断依据：`git diff --stat` 改动行数 + 涉及文件数。

**判定原则**：验证时间不应超过编码工作量；某子 target 是硬要求（如 `verify-env-format`）就直接调子 target，不调 `make verify` umbrella。

## 工作流

### Step 1：确认档位

```bash
git diff --stat       # 看改动量
git status            # 看跨文件分布
```

如果跨多个 service / cmd / 含 schema 或 .proto 改动 → 直接判重型。

### Step 2：Go 项目执行

**轻型**（单文件 / <20 行）：

```bash
# 找到改动文件所在 package
PKG_DIR=$(dirname <changed-file>)
go build ./${PKG_DIR}/... 2>&1
# 跑该 package 的目标测试（如果有 test 名匹配）
go test -run <relevant-test-name> ./${PKG_DIR}/... -count=1 2>&1
go vet ./${PKG_DIR}/... 2>&1
```

禁止跑 `go test ./...` 全量。

**中型**：

```bash
# 跑改动 package + 直接依赖该 package 的 reverse deps
go test ./<changed-package>/... -count=1 2>&1
go vet ./<changed-package>/... 2>&1
# env 一致性（如果改了 .env / config）
bash scripts/lint/check-env-consistency.sh 2>&1 || true
```

**重型**：

```bash
make verify 2>&1   # 项目通常封装了 build + test + lint + env-check
# 或显式：
go build ./... && go test ./... -count=1 && go vet ./...
```

### Step 3：TypeScript / 前端项目（如 ordo-fe）

**轻型** (`*.tsx` / `*.ts` 单文件):

```bash
npx tsc --noEmit -p <project>     # 只 type check 不输出
npx eslint <changed-file>
```

**中型 / 重型**：

```bash
npm run lint
npm run build       # tsc -b 会全量 type check
```

### Step 4：报告结果

输出格式（短，按 response-style.md 不模板化原则）：

```
Verify: <档位> · Go/TS

✓ build · ✓ vet · ✗ test (3 failed)
失败列表：
- <pkg>.TestXxx: <一行错误概要> @ file:line
- ...

建议：<具体下一步>
```

如果全过，**一行 done** 就行，不要堆 "All tests passed! 🎉" 这种。

## 反模式

- 不要默认跑 `go test ./...` 全量，违反开销分级
- 不要把 lint 失败误判成 test 失败（分开报）
- 不要"忽略"看似无关的报错（goimports diff、vet shadow 等）—— 报，让用户决定
- 不要在轻型改动跑 canary 部署验证
- 失败时不要直接"自己改了重试"。先报失败 + 失败原因，让用户决定要不要改

## 常用项目命令速查（按需扩展）

- `ordo-backend`：`make verify`、`make verify-env-format`、`make verify-cube-schema`、`make verify-idempotency-risk`
- `ordo-fe`：`npm run lint`、`npm run build`、`npm test`
