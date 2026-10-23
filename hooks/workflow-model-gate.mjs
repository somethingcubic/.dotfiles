#!/usr/bin/env node
// workflow-model-gate.mjs — PreToolUse(Workflow): workflow 脚本里每个 agent() 调用都必须在 opts 里显式写 model 和 effort。
// 由 orchestrator 按任务体量和难度选档（判断依据见 AGENTS.md「子 agent 选模型」）。
// meta.description 必须以类型标签开头（判断依据见 AGENTS.md「要不要开子 agent」）；[并行修复] 的每个 agent() 还必须带 isolation: 'worktree'。
// 只认对象字面量顶层的键（字符串、注释里写的不算）；给 agent 起别名会绕过检查，直接拦。
// 按名字调用的已保存 workflow 看不到脚本，不检查；输入不是 JSON 时放行（和其他 hook 一致）。

import { readFileSync } from 'node:fs'

let input
try { input = JSON.parse(readFileSync(0, 'utf8')) } catch { process.exit(0) }
const ti = input.tool_input || {}
let script = ti.script
if (ti.scriptPath) {
  try { script = readFileSync(ti.scriptPath, 'utf8') } catch { process.exit(0) }
}
if (!script) process.exit(0)

// 从 i 处的引号开始，返回字符串结束位置（指向收尾引号）
function skipString(src, i) {
  const q = src[i]
  for (i++; i < src.length && src[i] !== q; i++) if (src[i] === '\\') i++
  return i
}

// 跳过注释：返回注释结束位置，不是注释返回 -1
function skipComment(src, i) {
  if (src[i] === '/' && src[i + 1] === '/') { const e = src.indexOf('\n', i); return e < 0 ? src.length : e }
  if (src[i] === '/' && src[i + 1] === '*') { const e = src.indexOf('*/', i + 2); return e < 0 ? src.length : e + 1 }
  return -1
}

// 从 start（指向 open）开始找到匹配的 close，跳过字符串、模板字符串和注释
function matchEnd(src, start, open, close) {
  let depth = 0
  for (let i = start; i < src.length; i++) {
    const c = src[i]
    if (c === '"' || c === "'" || c === '`') { i = skipString(src, i); continue }
    const e = skipComment(src, i)
    if (e >= 0) { i = e; continue }
    if (c === open) depth++
    else if (c === close && --depth === 0) return i
  }
  return src.length
}

// 对象字面量 src[start] === '{' 的顶层键：返回 Map(键 → 值的原文，字符串值去掉引号)
function topLevelProps(src, start) {
  const end = matchEnd(src, start, '{', '}')
  const props = new Map()
  let depth = 0
  for (let i = start; i <= end; i++) {
    const c = src[i]
    if (depth === 1) {  // 顶层键，键名可以带引号：model: / 'model': / "model":
      const m = /^(['"]?)([A-Za-z_$][\w$]*)\1\s*:\s*/.exec(src.slice(i, i + 200))
      if (m && !/[\w$]/.test(src[i - 1] || '')) {
        const v = i + m[0].length
        if (src[v] === '"' || src[v] === "'" || src[v] === '`') {
          const ve = skipString(src, v)
          props.set(m[2], src.slice(v + 1, ve))
          i = ve
        } else {
          props.set(m[2], src.slice(v, v + 40))
          i = v - 1
        }
        continue
      }
    }
    if (c === '"' || c === "'" || c === '`') { i = skipString(src, i); continue }
    const e = skipComment(src, i)
    if (e >= 0) { i = e; continue }
    if (c === '{' || c === '[' || c === '(') { depth++; continue }
    if (c === '}' || c === ']' || c === ')') { depth--; continue }
  }
  return props
}

// 找出字符串、模板字符串和注释之外的 agent( 调用位置
function agentCalls(src) {
  const out = []
  for (let i = 0; i < src.length; i++) {
    const c = src[i]
    if (c === '"' || c === "'" || c === '`') { i = skipString(src, i); continue }
    const e = skipComment(src, i)
    if (e >= 0) { i = e; continue }
    const m = /^agent\s*\(/.exec(src.slice(i, i + 20))
    if (m && !/[\w$.]/.test(src[i - 1] || '')) { out.push([i, i + m[0].length - 1]); i += m[0].length - 2 }
  }
  return out
}

// 去掉字符串和注释内容，留给别名检查用
function codeOnly(src) {
  let out = ''
  for (let i = 0; i < src.length; i++) {
    const c = src[i]
    if (c === '"' || c === "'" || c === '`') { const e = skipString(src, i); out += c + c; i = e; continue }
    const e = skipComment(src, i)
    if (e >= 0) { i = e; continue }
    out += c
  }
  return out
}

const TAGS = /^\s*\[(并行只读|独立验证|大范围读取|并行修复)\]/
const bad = []
// 字符串和注释之外的第一个 export const meta = {
function findMeta(src) {
  for (let i = 0; i < src.length; i++) {
    const c = src[i]
    if (c === '"' || c === "'" || c === '`') { i = skipString(src, i); continue }
    const e = skipComment(src, i)
    if (e >= 0) { i = e; continue }
    const m = /^export\s+const\s+meta\s*=\s*\{/.exec(src.slice(i, i + 60))
    if (m) return i + m[0].length - 1
  }
  return -1
}
const metaAt = findMeta(script)
const desc = metaAt >= 0 ? topLevelProps(script, metaAt).get('description') : undefined
const tag = desc !== undefined ? TAGS.exec(desc) : null
if (!tag) bad.push('  meta.description 没有以类型标签开头')
if (/\b(const|let|var)\s+[\w$]+\s*=\s*agent\b(?!\s*\()|\bagent\s*\.\s*(bind|call|apply)\b|\b(globalThis|window|self)\s*\.\s*agent\b|\(\s*agent\s*\)\s*\(/.test(codeOnly(script))) {
  bad.push('  不要给 agent 起别名或间接调用（bind/call/apply、globalThis.agent、(agent)(...)），直接写 agent(...)')
}
for (const [at, open] of agentCalls(script)) {
  const close = matchEnd(script, open, '(', ')')
  // opts 是调用参数里最后一个顶层对象字面量
  let optsAt = -1
  for (let i = open + 1, depth = 0; i < close; i++) {
    const c = script[i]
    if (c === '"' || c === "'" || c === '`') { i = skipString(script, i); continue }
    const e = skipComment(script, i)
    if (e >= 0) { i = e; continue }
    if (c === '{' && depth === 0) { optsAt = i; i = matchEnd(script, i, '{', '}'); continue }
    if (c === '(' || c === '[') depth++
    else if (c === ')' || c === ']') depth--
  }
  const props = optsAt >= 0 ? topLevelProps(script, optsAt) : new Map()
  const missing = ['model', 'effort'].filter(k => !props.has(k))
  if (tag && tag[1] === '并行修复' && props.get('isolation') !== 'worktree') missing.push("isolation: 'worktree'")
  if (missing.length) {
    const line = script.slice(0, at).split('\n').length
    bad.push(`  第 ${line} 行 agent() 缺 ${missing.join(' 和 ')}`)
  }
}
if (!bad.length) process.exit(0)

process.stderr.write(
  'workflow-model-gate: workflow 脚本缺以下内容（model、effort、isolation 要在 agent() 的 opts 对象里直接写，不要放在变量里展开）：\n' +
  bad.join('\n') + '\n' +
  'model/effort 按 AGENTS.md「子 agent 选模型」判断：做错的代价、难度在推理还是在读得多（读得多就拆分）、能否便宜地验证。\n' +
  '类型标签按 AGENTS.md「要不要开子 agent」选一个：[并行只读] [独立验证] [大范围读取] [并行修复]；四种都不是就别开 workflow，在主会话里做。\n'
)
process.exit(2)
