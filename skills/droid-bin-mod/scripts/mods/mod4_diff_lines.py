#!/usr/bin/env python3
"""mod4: diff显示行数 20→99 行 (0 bytes)"""
import sys, re
sys.path.insert(0, str(__file__).rsplit('/', 2)[0])
from common import load_droid, save_droid, replace_one, V

data = load_droid()
original_size = len(data)

if re.search(rb'var ' + V + rb'=99,' + V + rb',', data):
    print("mod4 已应用，跳过")
    sys.exit(0)

# var XX=20, → var XX=99,
# 特征：后面跟变量声明(逗号+字母)，不跟数字赋值
data, _ = replace_one(
    data,
    rb'var (' + V + rb')=20,(' + V + rb'),',
    lambda m: b'var ' + m.group(1) + b'=99,' + m.group(2) + b',',
    'mod4 diff行数')

if len(data) != original_size:
    print(f"警告: 大小变化 {len(data) - original_size:+d} bytes")

save_droid(data)
print("mod4 完成")
