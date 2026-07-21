# Postmortem: 抑制类 guard 扫全文导致误伤 + 跨 pane 消息丢失

**日期**: 2026-06-17
**项目**: ordo_ai_spec_debug (`/Users/qiansenmiao/Documents/Projects/ordo_ai_spec_debug`)，作为 codex-driven-dev 的实现侧（CC = poc:4.2），orchestrator = poc:4.1
**严重程度**: 中（PR-E bug 在 review 阶段被拦截、未进 prod；message 丢失浪费一轮，无生产影响）

本会话连续交付 PR-D / PR-E / PR-C-runtime / 内存泄漏 P0 / ListJobs P0 / nginx logrotate。复盘聚焦两个真实失误节点。

## 时间线

### 事件 A：PR-E recency parser 的 rolling-window guard 误伤真实 freshness

- **发现**：PR-E（搜索 last-post recency 自然语言解析）实现里，为了让 AC6"rolling-window 表现类"（如 `近30天至少1条1M+视频`）不注入 `last_post_within_days`，我加了一个 `rollingWindowVolumeRe.MatchString(haystack)` 守卫，匹配 `N条/百万/M+/爆款/播放量` 等。我自测时只覆盖了"全空"和我自己加的少数 case，全过，提了 draft PR。
- **尝试（失败的方案）**：guard 作用在**整段 haystack** 上——只要文本任意位置出现这些词就 no-op。Codex review 给出反例并 reject：
  - `近30天内持续更新，平均播放量10万以上` 应注入 30，但 guard 命中"播放量"→ nil。
  - `最近更新时间：一个月内，交付形式：1条短视频` 应注入 30，但 guard 命中"1条"→ nil。
  - 我自测没覆盖"freshness + 邻近指标/分隔子句"共现场景。
- **解决**：复核 Codex 论点成立后，重定 rolling-window 信号定义——只认"匹配到的 recency 短语**同一子句尾部**的 post-count（N条）"，per-post 指标（平均播放量/百万/1M+）与 freshness 正交、彻底移出 guard。用 `FindStringSubmatchIndex` 取匹配位置，`recencyClauseHasPostCount(tail)` 只看到下一个分隔符为止。补 parser + handler 双层回归测试（freshness+邻近指标仍注入、rolling 输出量仍 no-op），全过后重交。Codex 复审通过。

### 事件 B：tmux 跨 pane 回报消息丢失

- **发现**：把 PR #1900 自评 send-keys 给 poc:4.1 后，pane 显示 `Working`，我未验证落地就转下一步。用户随后只发"重发"——消息没到。
- **根因**：发送时目标 pane 正 mid-turn（Working），send-keys 的输入被吞/未提交。我此前其它回报恰好 pane idle 才侥幸成功。
- **解决**：等 pane idle 后重发，并 `capture-pane | grep` 关键词确认 scrollback 出现消息尾部才算落地。

## 根因分析

### 事件 A
- **表面原因**: guard 正则在整段文本上 `MatchString`，把与 freshness 无关的邻近子句（指标/交付数量）当成抑制信号。
- **根本原因**: [推断] 我把"rolling-window 表现"模糊定义成"出现量词/指标词"，而没锚定它的**结构**——表现类的判别信号是"recency 窗口内的产出**计数**（N条）"，与"该窗口内是否发过帖"（freshness）正交；guard 该作用于"匹配片段的延续"，不是全文。
- **系统性因素**: [局部推断] 自测样本是我自己想的，缺少"正向行为 + 干扰项共现"的对抗样本；一个会改变"是否注入"的抑制分支，本应优先构造"应注入但有干扰词"的反例，而不是只测"应/不应"的干净句。

### 事件 B
- **表面原因**: pane 在 Working 时 send-keys 被吞。
- **根本原因**: 把"send-keys 返回成功"等同于"对方收到"——跨 pane 是无回执的外部通道。
- **系统性因素**: 协作回报缺一个"发送后验证落地"的固定收尾动作。

## 教训

1. **抑制类 guard 必须 scope 到匹配片段，且按"结构"而非"关键词出现"判别，并用共现反例测试守住。**
   - 适用场景: 任何"匹配到 X 后，再检测 Y 决定是否抑制/否决"的解析、过滤、分类逻辑（NLP parser、freshness/performance 区分、内容门控）。
   - 违反后果: guard 在全文命中无关子句 → 真实正向被静默否决；干净样本测不出来，要到 review 或线上才暴露。
   - 可执行: ①guard 只看匹配 span 的邻近/同一子句（用 `FindStringSubmatchIndex` 取位置 + 到分隔符为止）；②先想清抑制信号的"结构锚点"（这里是"窗口内产出计数 N条"），把正交维度（per-post 指标）排除在 guard 之外；③必测"应触发 + 邻近有抑制词"的对抗样本。

2. **跨 pane / 外部无回执通道发消息后，必须验证落地，尤其对方 Working 时。**
   - 适用场景: tmux send-keys 给协作 pane、任何无 ACK 的 IPC/外部投递。
   - 违反后果: 对方 mid-turn 时消息被吞，自以为已回报，浪费一轮往返（本次"重发"）。
   - 可执行: 发送后 `capture-pane -p -S -N | grep <消息关键词>` 确认 scrollback 出现；优先等 pane idle 再发；落空则重发。

3. **LSP 诊断与编译器冲突时，以编译器为准（本会话复发 3+ 次）。**
   - 适用场景: 编辑后 IDE/LSP 报 `does not implement / missing method` 等，但 `go build`/`go test` 通过。
   - 违反后果: 被陈旧 LSP 噪声带偏去"修"一个不存在的问题。
   - 可执行: 用 `go build ./pkg` + `go test ./pkg`（出 `ok` 即包编译通过）作为 ground truth，不被 mid-edit 的 LSP 快照误导。

## 行动项
- [ ] （建议沉淀 memory，待用户确认）教训 1、2 写入 auto memory（feedback 类型）。
- [ ] 后续若再写抑制/否决类 parser guard，按教训 1 的三步走，先列对抗样本再实现。
- [ ] 跨 pane 回报固定加"send → capture-pane 验证落地"收尾。
