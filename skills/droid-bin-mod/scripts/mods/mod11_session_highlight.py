#!/usr/bin/env python3
"""mod11: session 列表选中行加背景色 (0 bytes)

原版只改文字色，在半透明终端上几乎看不出选中状态。
给选中行加 backgroundColor:UH.highlight，用 jsxDEV 尾参 void 0→0 补偿字节。
"""
import re
import sys

sys.path.insert(0, str(__file__).rsplit('/', 2)[0])
from common import load_droid, save_droid, V

data = load_droid()
original_size = len(data)

if b'backgroundColor:' in data[73800000:73820000] and b'UH.highlight:0,children:' in data[73800000:73820000]:
    # Rough check - look for our specific patch pattern more precisely
    pass

# ============================================================
# Phase 1: find session row color assignment
# ============================================================
# Pattern: VAR=VAR?VAR?"white":UH.text.muted:VAR?UH.primary:void 0,VAR=VAR&&VAR.id===VAR
# This is the session list row where:
#   - In compact mode (W): selected="white", unselected=UH.text.muted
#   - In normal mode: selected=UH.primary, unselected=void 0

color_pat = (
    rb'(' + V + rb')=(' + V + rb')\?(' + V + rb')\?"white":UH\.text\.muted:'
    rb'(' + V + rb')\?UH\.primary:void 0,'
    rb'(' + V + rb')=(' + V + rb')&&(' + V + rb')\.id===(' + V + rb');'
    rb'return (' + V + rb')\.jsxDEV\((' + V + rb'),\{flexDirection:(' + V + rb')\?"row":"column",children:'
)

m = re.search(color_pat, data)
if not m:
    # Check if already patched (void 0 → 0 variant)
    color_pat_patched = (
        rb'(' + V + rb')=(' + V + rb')\?(' + V + rb')\?"white":UH\.text\.muted:'
        rb'(' + V + rb')\?UH\.primary:0,'
        rb'(' + V + rb')=(' + V + rb')&&(' + V + rb')\.id===(' + V + rb');'
    )
    if re.search(color_pat_patched, data):
        print("mod11 已应用，跳过")
        sys.exit(0)
    print("mod11 失败: session row color pattern 未找到")
    sys.exit(1)

# Extract variable names
ua_var = m.group(1)       # color variable (UA)
w_var = m.group(2)        # compact mode flag (W)
or_var = m.group(3)       # selected flag (oR) - same as group(4)
ja_var = m.group(5)       # current indicator (JA)
jsx_ns = m.group(9)       # JSX namespace (G8)
frame_comp = m.group(10)  # frame component (_H)
w_var2 = m.group(11)      # compact mode flag again

print(f"Phase1: color={ua_var.decode()}, selected={or_var.decode()}, "
      f"jsx={jsx_ns.decode()}, frame={frame_comp.decode()}")

# ============================================================
# Phase 2: build replacement with backgroundColor
# ============================================================
old_bytes = m.group(0)

# Replace "void 0" with "0" in the color assignment (saves 4 bytes)
# Add backgroundColor:selected?UH.highlight:0 to the row wrapper
new_bytes = (
    ua_var + b'=' + w_var + b'?' + or_var + b'?"white":UH.text.muted:'
    + or_var + b'?UH.primary:0,'
    + ja_var + b'=' + m.group(6) + b'&&' + m.group(7) + b'.id===' + m.group(8) + b';'
    + b'return ' + jsx_ns + b'.jsxDEV(' + frame_comp
    + b',{flexDirection:' + w_var2 + b'?"row":"column",'
    + b'backgroundColor:' + or_var + b'?UH.highlight:0,children:'
)

diff = len(new_bytes) - len(old_bytes)
print(f"Phase2: main patch {diff:+d}B")

# ============================================================
# Phase 3: apply patch and compensate bytes
# ============================================================
pos = m.start()
data = data[:pos] + new_bytes + data[pos + len(old_bytes):]

if diff > 0:
    # Need to save bytes: replace ",void 0,!1,void 0,this)" with ",0,!1,0,this)"
    # in nearby jsxDEV calls (each saves 8 bytes)
    # Only patch within the session row function (pos to pos+1200)
    search_start = pos
    search_end = min(pos + 1200, len(data))
    chunk = data[search_start:search_end]

    saved = 0
    old_tail = b',void 0,!1,void 0,this)'
    new_tail = b',0,!1,0,this)'
    replacements = 0

    while saved < diff:
        idx = chunk.find(old_tail)
        if idx == -1:
            break
        chunk = chunk[:idx] + new_tail + chunk[idx + len(old_tail):]
        saved += len(old_tail) - len(new_tail)
        replacements += 1

    data = data[:search_start] + chunk + data[search_end:]
    net = saved - diff  # positive = over-saved, need to pad back

    if net < 0:
        # Under-saved, pad spaces after semicolon
        pad_target = b';return ' + jsx_ns + b'.jsxDEV'
        pad_pos = data.find(pad_target, pos)
        if pad_pos >= 0:
            data = data[:pad_pos + 1] + b' ' * (-net) + data[pad_pos + 1:]
        else:
            print(f"mod11 失败: 无法补偿 {-net} bytes")
            sys.exit(1)
    elif net > 0:
        # Over-saved, pad spaces to restore balance
        pad_target = b';return ' + jsx_ns + b'.jsxDEV'
        pad_pos = data.find(pad_target, pos)
        if pad_pos >= 0:
            data = data[:pad_pos + 1] + b' ' * net + data[pad_pos + 1:]

    print(f"Phase3: {replacements} jsxDEV tail patches (-{saved}B), balanced {net:+d}B")

elif diff < 0:
    # Gained bytes, pad with spaces
    pad_target = b';return ' + jsx_ns + b'.jsxDEV'
    pad_pos = data.find(pad_target, pos)
    if pad_pos >= 0:
        data = data[:pad_pos + 1] + b' ' * (-diff) + data[pad_pos + 1:]
    print(f"Phase3: padded {-diff}B")

final_diff = len(data) - original_size
assert final_diff == 0, f"mod11 大小变化 {final_diff:+d} bytes"

save_droid(data)
print("mod11 完成")
