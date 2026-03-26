#!/usr/bin/env python3
"""检查 Claude Code 当前状态: 原版/已修改/部分修改"""
import re
from pathlib import Path

link = Path.home() / '.local/bin/claude'
target = link.resolve()
version = target.name

with open(target, 'rb') as f:
    data = f.read()

results = {}

# mod1: verbose 输出上下文
if b'createContext(!0)' in data and b'createContext(!1)' not in data:
    results['mod1'] = 'modified'  # 全部改为 !0
elif b'createContext(!1)' in data and b'createContext(!0)' not in data:
    results['mod1'] = 'original'  # 全部为 !1
else:
    # 混合状态或有其他 createContext - 用精确模式检测
    pattern = rb'S\(s\(\),1\),[A-Za-z_$][A-Za-z0-9_$]*=[A-Za-z_$][A-Za-z0-9_$]*\.createContext\((!.)\)'
    matches = list(re.finditer(pattern, data))
    if matches:
        values = set(m.group(1) for m in matches)
        if values == {b'!0'}:
            results['mod1'] = 'modified'
        elif values == {b'!1'}:
            results['mod1'] = 'original'
        else:
            results['mod1'] = 'partial'
    else:
        results['mod1'] = 'unknown'

# mod2: 错误行数限制
V = rb'[A-Za-z_$][A-Za-z0-9_$]*'
pattern_99 = rb'var ' + V + rb',' + V + rb'=99;var ' + V + rb'=X\('
pattern_10 = rb'var ' + V + rb',' + V + rb'=10;var ' + V + rb'=X\('

if re.search(pattern_99, data):
    results['mod2'] = 'modified'
elif re.search(pattern_10, data):
    results['mod2'] = 'original'
else:
    results['mod2'] = 'unknown'

# 环境变量
import os
bash_max = os.environ.get('BASH_MAX_OUTPUT_LENGTH', '')
env_status = f'已设置 ({bash_max})' if bash_max else '未设置 (默认 30000)'

# 备份状态
backup = target.parent / f"{version}.backup"
has_backup = backup.exists()

# 输出
total = len(results)
mod_count = sum(1 for v in results.values() if v == 'modified')
orig_count = sum(1 for v in results.values() if v == 'original')

labels = {
    'mod1': 'verbose 输出 (工具输出默认全量显示)',
    'mod2': '错误行数 (10→99)',
}

print(f"Claude Code v{version}")
print(f"路径: {target}")
print(f"备份: {'✓ 已备份' if has_backup else '○ 无备份'}")
print(f"BASH_MAX_OUTPUT_LENGTH: {env_status}")
print()

for name, status in results.items():
    icon = '✓' if status == 'modified' else '○' if status == 'original' else '?'
    label = {'modified': '已修改', 'original': '原版', 'unknown': '未知', 'partial': '部分'}[status]
    desc = labels.get(name, name)
    print(f"  {icon} {name}: {label}  ({desc})")

print()
if mod_count == total:
    print("结论: 已修改")
elif orig_count == total:
    print("结论: 原版")
else:
    print(f"结论: 部分修改 ({mod_count}/{total})")
