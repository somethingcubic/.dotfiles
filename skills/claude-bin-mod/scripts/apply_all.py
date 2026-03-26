#!/usr/bin/env python3
"""一键应用所有修改"""
import sys
import subprocess
from pathlib import Path

SCRIPTS = Path(__file__).parent

sys.path.insert(0, str(SCRIPTS))
from common import get_claude_path, get_version, create_backup, remove_codesign, add_codesign

print(f"Claude Code v{get_version()}")
print(f"路径: {get_claude_path()}")
print()

# 1. 备份
create_backup()

# 2. 移除签名
remove_codesign()

# 3. 执行修改
mods = sorted((SCRIPTS / 'mods').glob('mod*.py'))
failed = []
for mod in mods:
    print(f"\n--- {mod.name} ---")
    result = subprocess.run([sys.executable, str(mod)], capture_output=True, text=True)
    print(result.stdout, end='')
    if result.returncode != 0:
        print(f"失败: {result.stderr}")
        failed.append(mod.name)

# 4. 重新签名
print()
add_codesign()

# 5. 验证
print()
result = subprocess.run([str(get_claude_path()), '--version'], capture_output=True, text=True)
if result.returncode == 0:
    print(f"验证通过: {result.stdout.strip()}")
else:
    print(f"验证失败! 建议恢复: python3 {SCRIPTS}/restore.py")

if failed:
    print(f"\n警告: {len(failed)} 个修改失败: {', '.join(failed)}")
else:
    print("\n全部修改成功!")
