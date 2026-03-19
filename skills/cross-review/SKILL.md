---
name: cross-review
description: 基于 Hive 基础 skill/runtime 的双 Agent 交叉 PR 审查。通过 tmux HIVE 消息、status、artifact 组织协作。
metadata: {"cross-review-bot":{"emoji":"🔀","os":["darwin","linux"],"requires":{"bins":["tmux","droid","gh","python3","hive"]}}}
---

# Cross Review - 双 Agent 交叉审查

## Prerequisites

Cross Review 依赖以下外部 CLI，使用前必须安装：

```bash
pipx install git+https://github.com/notdp/hive.git   # hive CLI
brew install gh                                        # GitHub CLI
```

运行 `hive --help` 和 `gh --version` 确认安装成功。

---

通过 `hive` CLI 在当前 tmux window 中启动审查 Agent。
Orchestrator 就是当前 droid，Claude 和 GPT 出现在旁边的 pane 中。

## 1. 启动

`cross-review` 是建立在 `hive` 基础 skill 之上的 workflow skill。Factory skill frontmatter 目前没有原生的 `depends on` 机制，所以依赖关系由 Hive CLI 显式加载：先加载 `hive`，再加载 `cross-review` workflow。

Orchestrator 通过 `hive create` 初始化 workspace 和 team：

```bash
export CR_WORKSPACE="/tmp/cr-<safe_repo>-<pr_number>"
export HIVE_WORKSPACE="$CR_WORKSPACE"
export CR_TEAM="cr-<safe_repo>-<pr_number>"

hive create "$CR_TEAM" -d "Cross review PR #<pr_number>"           --workspace "$CR_WORKSPACE"           --reset-workspace           --state "repo=<repo>"           --state "pr-number=<pr_number>"           --state "base=<base>"           --state "branch=<branch>"
```

然后在阶段 1 中通过 `hive spawn --workflow cross-review` 启动 Claude 和 GPT。

---

## 2. 角色

| 角色 | 位置 | 职责 |
| --- | --- | --- |
| Orchestrator | 当前 pane（你） | 编排流程、判断共识、发最终评论 |
| Claude | split pane | 审查、交叉确认、执行修复 |
| GPT | split pane | 审查、交叉确认、验证修复 |

模型可通过环境变量覆盖：`CR_MODEL_CLAUDE`, `CR_MODEL_GPT`

---

## 3. 流程总览

```
开始 → 阶段1(并行审查) → 阶段2(判断共识)
                              ├─ both_ok ──────→ 阶段5(汇总)
                              ├─ same_issues ──→ 阶段4(修复) → 阶段5
                              └─ divergent ────→ 阶段3(交叉确认)
                                                   ├─ 无需修复 → 阶段5
                                                   └─ 需修复 ──→ 阶段4 → 阶段5
```

### 阶段执行

**每个阶段执行前，必须先读取对应 stages/ 文件获取详细指令。**

| 阶段 | Orchestrator 读取 | Agent 读取 |
| --- | --- | --- |
| 1 | `stages/1-review-orchestrator.md` | `stages/1-review-agent.md` |
| 2 | `stages/2-judge-orchestrator.md` | (不参与) |
| 3 | `stages/3-crosscheck-orchestrator.md` | `stages/3-crosscheck-agent.md` |
| 4 | `stages/4-fix-orchestrator.md` | `stages/4-fix-agent.md` / `stages/4-verify-agent.md` |
| 5 | `stages/5-summary-orchestrator.md` | (不参与) |

---

## 4. 通信架构

### 布局

```
当前 tmux window (由 hive 管理):
┌──────────────┬──────────────┐
│              │    claude    │
│ orchestrator ├──────────────┤
│   (你)       │     gpt      │
└──────────────┴──────────────┘
```

### 新协议

- **任务请求**：`hive send ... --artifact <request-path>`，直接把 `<HIVE ...>` 信封注入目标 pane
- **Agent 接收任务**：直接处理 pane 中收到的 `<HIVE ...>` 消息
- **产物**：写入 `artifacts/cross-review/...`
- **完成信号**：`hive status-set done ... --meta ...`
- **完成回传约定**：review / crosscheck / fix / verify 完成后，只发布 `status` + `cr.artifact`；不要再机械执行 `hive send orchestrator "... complete"`
- **等待**：`hive wait-status ...`
- **workflow 加载**：`hive spawn --workflow cross-review` 或 `hive workflow load <agent> cross-review`

`hive send` 只用于发新任务、澄清、blocker、请求 peer review 等需要对方立即采取动作的场景，不用于单纯 done 回执。

### 文件系统 workspace

```
$CR_WORKSPACE/
├── state/         # repo / pr-number / base / branch 等共享上下文
├── presence/      # hive who/status 输出的 presence 快照
├── status/        # agent 自发布状态
└── artifacts/     # review/crosscheck/fix/verify/summary 产物
```

---

## 5. Agent 启动

```bash
MODEL_CLAUDE="${CR_MODEL_CLAUDE:-custom:Claude-Opus-4.6-0}"
MODEL_GPT="${CR_MODEL_GPT:-custom:GPT-5.4-1}"

hive spawn claude -t "$CR_TEAM" -m "$MODEL_CLAUDE" --workflow cross-review \
  -e "HIVE_WORKSPACE=$CR_WORKSPACE" -e "CR_WORKSPACE=$CR_WORKSPACE"
hive spawn gpt -t "$CR_TEAM" -m "$MODEL_GPT" --workflow cross-review \
  -e "HIVE_WORKSPACE=$CR_WORKSPACE" -e "CR_WORKSPACE=$CR_WORKSPACE"
```

---

## 6. Orchestrator 行为规范

**禁止：**

- 直接操作 tmux（通过 `hive` 命令交互）
- 在阶段 1-4 自己做代码审查
- 在阶段 1-4 发布 PR 评论

**必须：**

- 通过 `hive spawn` 启动 Claude/GPT Agent
- 通过 `hive send` + artifact 路径发送任务
- 通过 `hive wait-status` 等待 agent 完成
- 通过 `hive who` / `hive status-show` 感知环境
- 在阶段 5 完成后调用 `hive delete` 清理

---

## 7. 工具清单

| 命令 | 用途 |
| --- | --- |
| `hive create` | 创建 team + 初始化 workspace |
| `hive spawn` | 启动 agent |
| `hive who` | 查看 team presence |
| `hive send` | 发送任务/消息 |
| `tmux <HIVE ...>` 消息 | agent 在 pane 中直接收到任务 |
| `hive status-set` | 发布状态 |
| `hive status-show` | 读取状态 |
| `hive wait-status` | 等待某个状态匹配 |
| `gh pr comment` / `gh api` | GitHub 评论与 review（仅阶段 5） |
| `hive delete` | 删 team + workspace |
