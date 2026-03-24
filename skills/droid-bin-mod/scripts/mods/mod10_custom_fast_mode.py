#!/usr/bin/env python3
"""mod10: custom model /fast support

用正则模式匹配代码结构，自动适应混淆变量名变化。
稳定锚点：字符串常量、方法名、代码结构模式。
"""
import re
import sys

sys.path.insert(0, str(__file__).rsplit('/', 2)[0])
from common import load_droid, save_droid, V

data = load_droid()
original_size = len(data)

if b'.sessionSettings.fast=C?D:""' in data:
    print('mod10 已应用，跳过')
    sys.exit(0)

total_diff = 0

# ============================================================
# Phase 1: 从稳定结构发现辅助函数
# ============================================================

# fast variant: function XXX(H){let T=YYY(H);return T?ZZZ.get(T):void 0}
fast_fn_pat = (
    rb'function (' + V + rb')\(H\)\{let T=(' + V + rb')\(H\);'
    rb'return T\?(' + V + rb')\.get\(T\):void 0\}'
)
fast_fn_matches = list(re.finditer(fast_fn_pat, data))
assert len(fast_fn_matches) == 1, f'fast variant: 预期 1 个匹配，找到 {len(fast_fn_matches)}'
fast_fn = fast_fn_matches[0].group(1)
zi_fn = fast_fn_matches[0].group(2)

# base variant: function XXX(H){let T=zi(H);return T?YYY[T]?.baseVariant:void 0}
base_fn_pat = (
    rb'function (' + V + rb')\(H\)\{let T=' + re.escape(zi_fn) +
    rb'\(H\);return T\?(' + V + rb')\[T\]\?\.baseVariant:void 0\}'
)
base_fn_m = re.search(base_fn_pat, data)
assert base_fn_m, 'base variant function 未找到'
base_fn = base_fn_m.group(1)

print(f'发现: fast={fast_fn.decode()}, base={base_fn.decode()}, resolver={zi_fn.decode()}')

# ============================================================
# Phase 2: 匹配 /fast 命令，提取 notify/state/info
# ============================================================

fast_cmd_pat = (
    rb'execute:\(H,T\)=>\{let\{addMessage:R\}=T,A=H\[0\]\?\.toLowerCase\(\);'
    rb'if\(A&&A!=="on"&&A!=="off"\)return '
    rb'(?P<notify>' + V + rb')\(R,`Invalid argument "\$\{H\[0\]\}"\.'
    rb' Usage: /fast, /fast on, or /fast off`\),\{handled:!0\};'
    rb'let L=(?P<state>' + V + rb')\(\),D=L\.getModel\(\),'
    rb'C=!A\|\|A==="on",h=!!' + re.escape(base_fn) + rb'\(D\);'
    rb'if\(C&&h\)\{let Q=(?P<info>' + V + rb')\(D\);return '
    rb'(?P=notify)\(R,`Already in fast mode '
    rb'\(\$\{Q\.shortDisplayName\|\|D\}\)`\),\{handled:!0\}\}'
    rb'if\(!C&&!h\)\{let Q=(?P=info)\(D\);return (?P=notify)\(R,'
    rb'`Already using base model '
    rb'\(\$\{Q\.shortDisplayName\|\|D\}\)`\),\{handled:!0\}\}'
    rb'let \$=C\?' + re.escape(fast_fn) + rb'\(D\):'
    + re.escape(base_fn) + rb'\(D\);'
    rb'if\(!\$\)\{let E=`No fast mode available for '
    rb'\$\{(?P=info)\(D\)\.shortDisplayName\|\|D\}`;'
    rb'return (?P=notify)\(R,E\),\{handled:!0\}\}'
    rb'try\{L\.setModel\(\$\)\}catch\(Q\)\{let E=Q instanceof Error\?'
    rb'Q\.message:"Failed to switch model";'
    rb'return (?P=notify)\(R,E\),\{handled:!0\}\}'
    rb'let W=(?P=info)\(\$\);return (?P=notify)\(R,'
    rb'`Switched to \$\{W\.shortDisplayName\|\|\$\}`\),\{handled:!0\}\}'
)

fast_cmd_m = re.search(fast_cmd_pat, data)
assert fast_cmd_m, '/fast 命令未匹配'
notify_fn = fast_cmd_m.group('notify')
state_fn = fast_cmd_m.group('state')
info_fn = fast_cmd_m.group('info')

print(f'发现: notify={notify_fn.decode()}, state={state_fn.decode()}, info={info_fn.decode()}')

# ============================================================
# Phase 3: 匹配并修补 j() 函数
# ============================================================

j_pat = (
    rb'(?P<arg>' + V + rb')\)=>\{let (?P<isSpec>' + V + rb')=(?P=arg)\?\.isSpecMode\?\?H\.isSpecMode\(\),'
    rb'(?P<model>' + V + rb')=(?P=arg)\?\.modelId\?\?'
    rb'\((?P=isSpec)\?H\.getSpecModeModel\(\):H\.getModel\(\)\),'
    rb'(?P<effort>' + V + rb')=(?P=arg)\?\.reasoningEffort\?\?'
    rb'\((?P=isSpec)\?H\.getSpecModeReasoningEffort\(\):H\.getReasoningEffort\(\)\),'
    rb'(?P<customs>' + V + rb')=(?P<customsFn>' + V + rb')\(\)\.getCustomModels\(\),'
    rb'(?P<cm>' + V + rb')=(?P<lookupFn>' + V + rb')\((?P=model),(?P=customs)\)\?\?null,'
    rb'(?P<modelOut>' + V + rb')=(?P=cm)\?(?P=cm)\.model:(?P=model),'
    rb'(?P<prov>' + V + rb')=(?P<infoFn>' + V + rb')\((?P=model)\)\.modelProvider,'
    rb'(?P<config>' + V + rb'),'
    rb'(?P<resolved>' + V + rb')=(?P=cm)\?'
    rb'(?P<helperFn>' + V + rb')\((?P=cm)\.model\):(?P=model);'
    rb'if\((?P=resolved)\)try\{(?P=config)='
    rb'(?P<resolverFn>' + V + rb')\(\{modelId:(?P=resolved)\}\)\}catch\{\}'
    rb'return\{model:(?P=modelOut),provider:(?P=prov),'
    rb'apiModelProvider:(?P=config)\?\.apiModelProvider,'
    rb'config:(?P=config),customModel:(?P=cm),'
    rb'isSpecMode:(?P=isSpec),reasoningEffort:(?P=effort)\}'
)

j_m = re.search(j_pat, data)
assert j_m, 'j() 函数未匹配'
d = j_m.groupdict()

if d['infoFn'] != info_fn:
    print(f'注意: j() infoFn={d["infoFn"].decode()} != /fast info={info_fn.decode()}')

j_new = (
    d['arg'] + b')=>{let ' + d['isSpec'] + b'=' + d['arg'] + b'?.isSpecMode??H.isSpecMode(),'
    + d['model'] + b'=' + d['arg'] + b'?.modelId??('
    + d['isSpec'] + b'?H.getSpecModeModel():H.getModel()),'
    + d['effort'] + b'=' + d['arg'] + b'?.reasoningEffort??('
    + d['isSpec'] + b'?H.getSpecModeReasoningEffort():H.getReasoningEffort()),'
    + d['customs'] + b'=' + d['customsFn'] + b'().getCustomModels(),'
    + b'W0=' + state_fn + b'().sessionSettings.fast===' + d['model'] + b','
    + d['cm'] + b'=' + d['lookupFn'] + b'('
    + d['model'] + b',' + d['customs'] + b')??null,'
    + d['modelOut'] + b'=' + d['cm'] + b'?' + d['cm'] + b'.model:'
    + d['model'] + b','
    + d['prov'] + b'=' + d['infoFn'] + b'(' + d['model'] + b').modelProvider,'
    + d['config'] + b','
    + d['resolved'] + b'=' + d['cm'] + b'?(W0?'
    + fast_fn + b'(' + d['cm'] + b'.model)??'
    + d['helperFn'] + b'(' + d['cm'] + b'.model):'
    + d['helperFn'] + b'(' + d['cm'] + b'.model)):'
    + d['model'] + b';'
    + b'if(' + d['resolved'] + b')try{' + d['config'] + b'='
    + d['resolverFn'] + b'({modelId:' + d['resolved'] + b'})}catch{}'
    + b'return{model:' + d['modelOut'] + b',provider:' + d['prov'] + b','
    + b'apiModelProvider:' + d['config'] + b'?.apiModelProvider,'
    + b'config:' + d['config'] + b',customModel:' + d['cm'] + b','
    + b'isSpecMode:' + d['isSpec'] + b',reasoningEffort:' + d['effort'] + b'}'
)

j_diff = len(j_new) - len(j_m.group(0))
data = data[:j_m.start()] + j_new + data[j_m.end():]
total_diff += j_diff
print(f'j() 注入: {j_diff:+d} bytes')

# ============================================================
# Phase 4: 匹配并修补 /fast 命令
# ============================================================

# j() 修改后偏移变化，重新搜索
fast_cmd_m2 = re.search(fast_cmd_pat, data)
assert fast_cmd_m2, '/fast 命令二次匹配失败'

fast_new = (
    b'execute:(H,T)=>{let{addMessage:R}=T,A=H[0]?.toLowerCase();'
    b'if(A&&A!=="on"&&A!=="off")return '
    + notify_fn + b'(R,`Bad arg "${H[0]}". Use /fast [on|off]`),{handled:!0};'
    b'let L=' + state_fn + b'(),D=L.getModel(),C=!A||A==="on",'
    b'B=D[6]===":",Q=' + info_fn + b'(D),'
    b'h=B?L.sessionSettings.fast===D:!!' + base_fn + b'(D),'
    b'$=B?D:C?' + fast_fn + b'(D):' + base_fn + b'(D);'
    b'if(C&&h)return ' + notify_fn
    + b'(R,`Already fast (${Q.shortDisplayName||D})`),{handled:!0};'
    b'if(!C&&!h)return ' + notify_fn
    + b'(R,`Already base (${Q.shortDisplayName||D})`),{handled:!0};'
    b'if(B){if(C&&!' + fast_fn + b'(Q.id))$=void 0;'
    b'else L.sessionSettings.fast=C?D:"",'
    b'L.currentSessionId&&L.saveSessionSettings('
    b'{async:!0,shouldSyncToCloud:!0})}'
    b'if(!$)return ' + notify_fn
    + b'(R,`No fast for ${Q.shortDisplayName||D}`),{handled:!0};'
    b'try{B||L.setModel($)}catch(h){return ' + notify_fn
    + b'(R,h instanceof Error?h.message:"Switch failed"),{handled:!0}}'
    b'return ' + notify_fn + b'(R,B?`Fast ${C?"on":"off"} '
    b'(${Q.shortDisplayName||D})`:`Switched to ${'
    + info_fn + b'($).shortDisplayName||$}`),{handled:!0}}'
)

fast_diff = len(fast_new) - len(fast_cmd_m2.group(0))
data = data[:fast_cmd_m2.start()] + fast_new + data[fast_cmd_m2.end():]
total_diff += fast_diff
print(f'/fast 命令: {fast_diff:+d} bytes')

# ============================================================
# Phase 5: 动态字节补偿
# ============================================================

# 可用补偿池：稳定字符串常量 (按节省量降序)
COMP_POOL = [
    (b'Install and set up Git AI for tracking AI-generated code attribution',
     b'Install and set up Git AI'),
    (b'Enable fast mode for the current model (/fast off to disable)',
     b'Toggle fast mode now'),
    (b'Generate a blog post style semantic diff for changes',
     b'Generate semantic diff'),
    (b'Favorite the current session for quick access',
     b'Favorite session'),
    (b'Show settings configuration errors',
     b'Show config issue'),
    (b'Manage plugins and marketplaces',
     b'Manage plugins'),
    (b'Fork the current session',
     b'Fork session'),
]

if total_diff > 0:
    remaining = total_diff
    for old, new in COMP_POOL:
        if remaining <= 0:
            break
        if old not in data:
            continue
        savings = len(old) - len(new)
        if savings <= remaining:
            data = data.replace(old, new, 1)
            remaining -= savings
            print(f'  补偿 -{savings}B: {new.decode()}')
        else:
            padded = new + b' ' * (savings - remaining)
            data = data.replace(old, padded, 1)
            print(f'  补偿 -{remaining}B (partial): {new.decode()}')
            remaining = 0

    if remaining > 0:
        print(f'ERROR: 补偿不足 {remaining}B，补偿池已耗尽')
        save_droid(data)
        sys.exit(1)

    max_pool = sum(len(o) - len(n) for o, n in COMP_POOL)
    print(f'  补偿池余量: {max_pool - total_diff}B / {max_pool}B')

elif total_diff < 0:
    print(f'WARNING: 负字节差异 {total_diff}，可能需要填充')

final_diff = len(data) - original_size
assert final_diff == 0, f'最终大小不匹配: {final_diff:+d}B'

save_droid(data)
print(f'mod10 完成 (net 0 bytes)')
