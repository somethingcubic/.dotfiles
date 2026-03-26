#!/usr/bin/env python3
"""mod2: 错误输出行数限制 10 → 99 (0 bytes)

非 verbose 模式下，错误输出默认只显示 10 行，超出后显示:
  "... +N lines (ctrl+o to see all)"

修改 gZq=10 → gZq=99，显示 99 行再折叠。

定位方式: "var V,V,V=10;var V=X(" 紧接在 error 渲染函数之后
支持 2~4 个逗号分隔变量，最后一个 =10
"""
import sys
import re
sys.path.insert(0, str(__file__).rsplit('/', 2)[0])
from common import load_binary, save_binary, V

data = load_binary()
original_size = len(data)

# 匹配: var V,V,V=10;var V=X( (支持 2~4 个变量)
pattern = rb'var ' + V + rb'(?:,' + V + rb'){1,3}=10;var ' + V + rb'=X\('

matches = list(re.finditer(pattern, data))
if not matches:
    print("mod2 失败: 未找到错误行数配置")
    sys.exit(1)

print(f"找到 {len(matches)} 处 mOA=10")

new_data = bytearray(data)
for m in reversed(matches):
    sub = m.group(0)
    idx = sub.index(b'=10;')
    offset = m.start() + idx + 1  # 指向 '1' in '10'
    new_data[offset] = ord('9')
    new_data[offset + 1] = ord('9')
    print(f"  offset {offset}: 10 -> 99")

data = bytes(new_data)
assert len(data) == original_size, f"大小变化 {len(data) - original_size:+d} bytes!"

save_binary(data)
print(f"mod2 完成: {len(matches)} 处修改")
