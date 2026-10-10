#!/usr/bin/env node
// workflow-model-gate.mjs — PreToolUse(Workflow): workflow 脚本里每个 agent() 调用都必须在 opts 里显式写 model 和 effort。
// 由 orchestrator 按任务体量和难度选档（档位表见 AGENTS.md「子 agent 选模型」）。
// 按名字调用的已保存 workflow 看不到脚本，不检查。

import { readFileSync } from 'node:fs'

const input = JSON.parse(readFileSync(0, 'utf8'))
const ti = input.tool_input || {}
let script = ti.script
if (ti.scriptPath) {
  try { script = readFileSync(ti.scriptPath, 'utf8') } catch { process.exit(0) }
}
if (!script) process.exit(0)

// 从 start（指向 '('）开始找到匹配的 ')'，跳过字符串、模板字符串和注释
function callEnd(src, start) {
  let depth = 0
  for (let i = start; i < src.length; i++) {
    const c = src[i]
    if (c === '"' || c === "'" || c === '`') {
      for (i++; i < src.length && src[i] !== c; i++) if (src[i] === '\\') i++
      continue
    }
    if (c === '/' && src[i + 1] === '/') { while (i < src.length && src[i] !== '\n') i++; continue }
    if (c === '/' && src[i + 1] === '*') { i = src.indexOf('*/', i + 2); if (i < 0) return src.length; i++; continue }
    if (c === '(') depth++
    else if (c === ')' && --depth === 0) return i
  }
  return src.length
}

// 找出字符串、模板字符串和注释之外的 agent( 调用位置
function agentCalls(src) {
  const out = []
  for (let i = 0; i < src.length; i++) {
    const c = src[i]
    if (c === '"' || c === "'" || c === '`') {
      for (i++; i < src.length && src[i] !== c; i++) if (src[i] === '\\') i++
      continue
    }
    if (c === '/' && src[i + 1] === '/') { while (i < src.length && src[i] !== '\n') i++; continue }
    if (c === '/' && src[i + 1] === '*') { i = src.indexOf('*/', i + 2); if (i < 0) break; i++; continue }
    const m = /^agent\s*\(/.exec(src.slice(i, i + 20))
    if (m && !/[\w$.]/.test(src[i - 1] || '')) { out.push([i, i + m[0].length - 1]); i += m[0].length - 2 }
  }
  return out
}

const bad = []
for (const [at, open] of agentCalls(script)) {
  const call = script.slice(at, callEnd(script, open) + 1)
  const missing = ['model', 'effort'].filter(k => !new RegExp(`\\b${k}\\s*:`).test(call))
  if (missing.length) {
    const line = script.slice(0, at).split('\n').length
    bad.push(`  第 ${line} 行 agent() 缺 ${missing.join(' 和 ')}`)
  }
}
if (!bad.length) process.exit(0)

process.stderr.write(
  'workflow-model-gate: workflow 里每个 agent() 都要在 opts 里直接写 model 和 effort（不要放在变量里展开）。\n' +
  bad.join('\n') + '\n' +
  '按 AGENTS.md 档位表选：检索/机械 → haiku+low；常规实现 → sonnet+medium；spec/review/复杂调试 → opus+high；高风险对抗 review → opus+xhigh。\n'
)
process.exit(2)
