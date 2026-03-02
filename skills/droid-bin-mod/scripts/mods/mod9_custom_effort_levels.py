#!/usr/bin/env python3
"""mod9: custom model 支持完整 effort 级别 (+66 bytes)

问题: wR() 对 custom model 硬编码 supportedReasoningEfforts 为 ["off","low","medium","high"]，
缺少 anthropic 的 "max" 和 openai 的 "xhigh"。

修改: 根据 provider 返回正确的 effort 列表:
  - openai:    ["none","low","medium","high","xhigh"]
  - anthropic: ["off","low","medium","high","max"]  (也作为其他 provider 的默认)

字节: +66 bytes，由 comp_universal.py 统一补偿。
"""
import sys
sys.path.insert(0, str(__file__).rsplit('/', 2)[0])
from common import load_droid, save_droid

data = load_droid()

if b'T.provider=="openai"' in data:
    print("mod9 已应用，跳过")
    sys.exit(0)

OLD = b'supportedReasoningEfforts:L?["off","low","medium","high"]:["none"]'
NEW = b'supportedReasoningEfforts:L?T.provider=="openai"?["none","low","medium","high","xhigh"]:["off","low","medium","high","max"]:["none"]'

if OLD not in data:
    print("错误: wR() 中的 effort 列表未找到")
    sys.exit(1)

data = data.replace(OLD, NEW, 1)
diff = len(NEW) - len(OLD)
print(f"mod9: effort 列表已修改 ({diff:+d} bytes)")
save_droid(data)
