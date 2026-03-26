#!/usr/bin/env python3
"""
独立恢复脚本 - Claude Code 坏了也能用

用法:
    python3 restore.py           # 恢复当前版本备份
    python3 restore.py --list    # 列出所有备份
    python3 restore.py 2.1.34    # 恢复指定版本
"""

import sys
import shutil
from pathlib import Path

CLAUDE_LINK = Path.home() / ".local" / "bin" / "claude"
VERSIONS_DIR = Path.home() / ".local" / "share" / "claude" / "versions"


def get_current():
    """获取当前版本路径"""
    if not CLAUDE_LINK.exists():
        print(f"错误: {CLAUDE_LINK} 不存在")
        sys.exit(1)
    return CLAUDE_LINK.resolve()


def list_backups():
    backups = sorted(VERSIONS_DIR.glob("*.backup"))
    if not backups:
        print("无备份")
        return
    print("可用备份:")
    for b in backups:
        size_mb = b.stat().st_size / 1024 / 1024
        version = b.name.replace('.backup', '')
        print(f"  {version} ({size_mb:.1f} MB) - {b}")


def restore(version=None):
    current = get_current()

    if version:
        backup = VERSIONS_DIR / f"{version}.backup"
    else:
        # 恢复当前版本的备份
        backup = current.parent / f"{current.name}.backup"

    if not backup.exists():
        print(f"错误: {backup} 不存在")
        list_backups()
        sys.exit(1)

    # 先删除再复制，避免 macOS 保留旧元数据导致签名失效
    target = current if not version else VERSIONS_DIR / version
    if target.exists():
        target.unlink()
    shutil.copy2(backup, target)
    print(f"已恢复: {backup.name} -> {target.name}")

    # macOS: 如果需要重新签名
    import platform
    if platform.system() == 'Darwin':
        import subprocess
        result = subprocess.run(
            ['codesign', '-v', str(target)],
            capture_output=True, text=True
        )
        if result.returncode != 0:
            subprocess.run(['codesign', '-s', '-', str(target)], check=True)
            print("已重新签名")
        else:
            print("签名完好，无需重签")


if __name__ == "__main__":
    if len(sys.argv) > 1:
        if sys.argv[1] == "--list":
            list_backups()
        else:
            restore(sys.argv[1])
    else:
        restore()
