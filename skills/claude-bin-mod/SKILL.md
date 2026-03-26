---
name: claude-bin-mod
description: Claude Code Binary Modifier
---

# Claude Code Binary Modifier

修改 Claude Code CLI 二进制文件，禁用输出折叠，实现默认展开显示。

## 使用流程

### 如果用户说"修改 claude"或"修改 claude code"

**直接执行一键修改脚本：**

```bash
python3 ~/.claude/skills/claude-bin-mod/scripts/apply_all.py
```

修改完成后告诉用户：**新开一个 Claude Code 窗口即可生效。**

### 如果用户说"检查 claude 状态"或"claude 修改状态"

```bash
python3 ~/.claude/skills/claude-bin-mod/scripts/status.py
```

### 如果用户说"恢复 claude"

```bash
python3 ~/.claude/skills/claude-bin-mod/scripts/restore.py          # 恢复当前版本
python3 ~/.claude/skills/claude-bin-mod/scripts/restore.py --list   # 列出备份
python3 ~/.claude/skills/claude-bin-mod/scripts/restore.py 2.1.34   # 恢复指定版本
```

### 如果用户说"测试 claude 修改"

在当前会话中执行以下命令验证修改效果：

```bash
# 测试 mod1 (输出折叠) - 应该看到完整 20 行，不被折叠
seq 1 20

# 测试 mod2 (错误行数) - 错误输出应显示最多 99 行
```

## 修改原理

### 二进制路径

```
~/.local/bin/claude → ~/.local/share/claude/versions/{version}  (symlink)
```

### 修改汇总

| # | 修改项 | 原始 | 修改后 | 字节 | 说明 |
|---|--------|------|--------|------|------|
| 1 | verbose 上下文 | `createContext(!1)` | `createContext(!0)` | 0 | 工具输出默认全量显示 |
| 2 | 错误行数限制 | `mOA=10` | `mOA=99` | 0 | 错误输出从 10 行增到 99 行 |
| env | 环境变量 | 默认 30000 | 150000 | - | `BASH_MAX_OUTPUT_LENGTH` in ~/.zshrc |

所有修改均为 0 字节大小变化，无需补偿。

### mod1: verbose 输出上下文 (核心)

**原始代码:**

```javascript
// verbose context 默认 false - 非 transcript 模式下折叠输出
zK_ = byT.createContext(!1)  // !1 = false

// tM 组件: 根据 verbose 决定是否折叠
function tM({content, verbose, isError}) {
  let D = VK_();              // 读取 context (默认 false)
  let $ = verbose || D;       // verbose 或 context 为 true 才全量显示
  if ($) return 全量输出;
  else   return 折叠输出 + "… +N lines";
}
```

**修改:** `createContext(!1)` → `createContext(!0)`

效果: verbose context 默认为 true，所有工具输出在 prompt 视图也全量显示。

### mod2: 错误输出行数限制

**原始代码:**

```javascript
var mOA = 10;  // 错误最多显示 10 行

// 非 verbose 时只显示前 10 行
result.split('\n').slice(0, mOA).join('\n')
// 超出后显示: "… +N lines (ctrl+o to see all)"
```

**修改:** `mOA=10` → `mOA=99`

### 环境变量: BASH_MAX_OUTPUT_LENGTH

控制 bash 命令输出在发送给模型前的最大字符数。
- 默认: 30000 字符
- 最大: 150000 字符
- 超出后显示: `[N lines truncated] ...`

在 `~/.zshrc` 中添加:
```bash
export BASH_MAX_OUTPUT_LENGTH=150000
```

## 修改脚本

```
scripts/
├── common.py                  # 共享工具函数
├── mods/
│   ├── mod1_verbose_output.py # verbose 上下文 !1→!0 (0 bytes)
│   └── mod2_error_lines.py    # 错误行数 10→99 (0 bytes)
├── apply_all.py               # 一键应用所有修改
├── status.py                  # 检查当前状态
└── restore.py                 # 恢复原版
```

### 手动执行流程

```bash
# 1. 备份 + 移除签名
cp ~/.local/share/claude/versions/$(claude --version | cut -d' ' -f1) \
   ~/.local/share/claude/versions/$(claude --version | cut -d' ' -f1).backup
codesign --remove-signature ~/.local/share/claude/versions/$(claude --version | cut -d' ' -f1)

# 2. 执行修改
python3 ~/.claude/skills/claude-bin-mod/scripts/mods/mod1_verbose_output.py
python3 ~/.claude/skills/claude-bin-mod/scripts/mods/mod2_error_lines.py

# 3. 重新签名
codesign -s - ~/.local/share/claude/versions/$(claude --version | cut -d' ' -f1)
```

## 版本升级后

Claude Code 自动更新后修改会失效，需要重新执行:

```bash
python3 ~/.claude/skills/claude-bin-mod/scripts/apply_all.py
```

脚本使用正则匹配，自动适应混淆后的变量名变化。

### 脚本失败排查

```bash
# 1. 检查特征字符串是否存在
strings ~/.local/share/claude/versions/$(claude --version | cut -d' ' -f1) | grep "createContext"
strings ~/.local/share/claude/versions/$(claude --version | cut -d' ' -f1) | grep "isTruncated"

# 2. 检查 verbose context 模式
strings ~/.local/share/claude/versions/$(claude --version | cut -d' ' -f1) | grep "useContext"
```

## 安全说明

- 仅影响本地 UI 渲染，不影响 API 通信
- 不发送二进制哈希或签名信息到服务器
- 备份存储在 `~/.local/share/claude/versions/{version}.backup`
