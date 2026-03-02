#!/usr/bin/env python3
"""mod1: 截断条件短路，永远返回原文 (0 bytes)"""
import sys
sys.path.insert(0, str(__file__).rsplit('/', 2)[0])
from common import load_droid, save_droid, replace_one, V

data = load_droid()
original_size = len(data)

if b'if(!0||!' in data:
    print("mod1 已应用，跳过")
    sys.exit(0)

# if(!X&&!Y)return{text:Z,isTruncated:!1} → if(!0||!Y)...
data, _ = replace_one(
    data,
    rb'if\(!(' + V + rb')&&!(' + V + rb')\)(return\{text:' + V + rb',isTruncated:!1\})',
    lambda m: b'if(!0' + b' ' * (len(m.group(1)) - 1) + b'||!' + m.group(2) + b')' + m.group(3),
    'mod1 截断条件')

assert len(data) == original_size, f"mod1 大小变化 {len(data) - original_size:+d} bytes"

save_droid(data)
print("mod1 完成")
