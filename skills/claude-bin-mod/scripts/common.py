"""共享工具函数 - Claude Code binary modification"""
import re
import os
import subprocess
from pathlib import Path

# Claude Code 二进制路径 (symlink → 实际版本)
CLAUDE_LINK = Path.home() / '.local/bin/claude'
V = rb'[A-Za-z_$][A-Za-z0-9_$]*'


def get_claude_path():
    """获取 Claude Code 实际二进制路径 (解析 symlink)"""
    if not CLAUDE_LINK.exists():
        raise FileNotFoundError(f"{CLAUDE_LINK} 不存在")
    return CLAUDE_LINK.resolve()


def get_version():
    """获取 Claude Code 版本号"""
    path = get_claude_path()
    return path.name  # 版本号是文件名, 如 "2.1.34"


def load_binary():
    """加载 Claude Code 二进制"""
    path = get_claude_path()
    with open(path, 'rb') as f:
        return f.read()


def save_binary(data):
    """保存 Claude Code 二进制"""
    path = get_claude_path()
    with open(path, 'wb') as f:
        f.write(data)


def backup_exists():
    """检查当前版本备份是否存在"""
    version = get_version()
    backup = get_claude_path().parent / f"{version}.backup"
    return backup.exists()


def create_backup():
    """为当前版本创建备份"""
    path = get_claude_path()
    backup = path.parent / f"{path.name}.backup"
    if backup.exists():
        print(f"备份已存在: {backup}")
        return backup
    import shutil
    shutil.copy2(path, backup)
    print(f"已备份: {path.name} -> {backup.name}")
    return backup


def remove_codesign():
    """macOS: 移除代码签名"""
    import platform
    if platform.system() == 'Darwin':
        path = get_claude_path()
        subprocess.run(['codesign', '--remove-signature', str(path)], check=True)
        print("已移除代码签名")


def add_codesign():
    """macOS: 重新签名"""
    import platform
    if platform.system() == 'Darwin':
        path = get_claude_path()
        subprocess.run(['codesign', '-s', '-', str(path)], check=True)
        print("已重新签名")


def replace_all_occurrences(data, pattern, replacer, name):
    """替换所有匹配，返回 (新data, 匹配数, 字节变化)"""
    matches = list(re.finditer(pattern, data))
    if not matches:
        raise ValueError(f"{name} 未找到!")

    total_diff = 0
    new_data = bytearray(data)

    # 从后往前替换，避免偏移量变化
    for m in reversed(matches):
        old = m.group(0)
        new = replacer(m)
        start, end = m.start(), m.end()
        new_data[start:end] = new
        total_diff += len(new) - len(old)

    print(f"{name}: 找到 {len(matches)} 处, 替换后 {total_diff:+d} bytes")
    return bytes(new_data), len(matches), total_diff
