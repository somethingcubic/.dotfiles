#!/usr/bin/env python3
"""mod1: 工具输出默认全量显示 (0 bytes)

将 verbose context 默认值从 false 改为 true:
  createContext(!1) → createContext(!0)

定位方式: 在 x(Y_(),1) 赋值链末尾的 createContext(!1)
这是唯一同时满足以下条件的 createContext 调用:
  - 前面紧跟分号 ;V=V.createContext(!1)
  - 属于 verbose/showAll 渲染上下文模块 (eT 组件读取此 context)
"""
import sys
sys.path.insert(0, str(__file__).rsplit('/', 2)[0])
from common import load_binary, save_binary, replace_all_occurrences, V

data = load_binary()
original_size = len(data)

# 匹配: x(Y_(),1);V=V.createContext(!1)
# 分号+createContext(!1) 是此上下文的唯一特征
# 只改 createContext(!1) 为 createContext(!0)
pattern = (
    rb'x\(Y_\(\),1\);' + V + rb'=' + V + rb'\.createContext\((!1)\)'
)

def replacer(m):
    old = m.group(0)
    return old.replace(b'createContext(!1)', b'createContext(!0)')

data, count, diff = replace_all_occurrences(data, pattern, replacer, 'mod1 verbose输出')

assert len(data) == original_size, f"大小变化 {len(data) - original_size:+d} bytes!"
save_binary(data)
print(f"mod1 完成: {count} 处修改")
