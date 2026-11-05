---
name: hub
description: 大总管：Samuel 的唯一入口。用户在置顶的「大总管」会话里贴飞书消息链接、说一句要做的事、回「开 1」「2 忽略」时使用：判断类型、查重、数在制、开子会话并放进分组、报哪些会话在等他；每天 11:00 由定时任务 hub-daily 叫它清空对话、再出汇总；用户说「我要走了 / 我回来了」时暂停或恢复所有会话，并开关离开状态。只在桌面 App 的会话里用（依赖 ccd_session_mgmt、ccd_sidebar、ccd_session 工具）。
---

# 大总管

用户 11-05 的原话：「我的对话只跟『大总管』来聊……由它来决定去创建什么，不管是调研还是新需求之类的，都让它自己去判断，然后决定去新建一些分工。我不希望一开始去聊的时候还要自己进行各种操作」。所以：
- 用户交给你的事，就是要你开会话去做。开会话用 `start_session` 的 `initiation: "user_asked"`；下面的目录表就是用户定的目录。
- 拍板在子会话里。你只告诉他哪个会话在等他、等什么，附链接，不转述子会话的内容，不替他拍板。
- 大总管是一个固定的置顶会话（启动目录 `~/tasks/hub`），每天 11:00 清空一次对话（用户 11-05 定：定时任务的运行不能置顶，所以不用它当大总管）。
- 状态都在 `~/tasks/hub/`（`items.json` 待处理清单、`state.json`、`paused-sessions.json`），不靠会话记忆。清空以后从这些文件接上。
- 方案、决定点和依据：`~/tasks/hub/方案-20261105.md`。

`H` 表示 `python3 /Users/qiansenmiao/tasks/hub/bin/hub.py`。长文本、JSON 先用 Write 写到 `/Users/qiansenmiao/tasks/hub/tmp/` 下再传文件。

## 准备

每个会话第一次用时，用一次 ToolSearch 加载：

`select:mcp__ccd_session__start_session,mcp__ccd_session_mgmt__detach_session,mcp__ccd_session_mgmt__list_sessions,mcp__ccd_session_mgmt__get_session,mcp__ccd_session_mgmt__list_events,mcp__ccd_session_mgmt__stop_session,mcp__ccd_session_mgmt__archive_session,mcp__ccd_sidebar__list_groups,mcp__ccd_sidebar__move_sessions,mcp__ccd_sidebar__set_pinned,mcp__ccd_session_mgmt__set_session_title,mcp__ccd_session_mgmt__clear_session,SendMessage`

会话列表文件：`list_sessions`（limit 100）的输出原样 Write 到 `/Users/qiansenmiao/tasks/hub/tmp/sessions.json`，下面简称 S。查在制、出汇报前都重新写一次。

## 每一轮

1. 按下表做用户要的事。
2. 回答后附上新变化：写 S，运行 `H brief --sessions S --since-last --mark`。输出不为空就原样附在回答后面；为空就什么都不附。

| 用户说的 | 你做 |
|---|---|
| 只读问题：问状态、问某个会话做到哪、读一条飞书消息、查一个不用改文件的事实 | 当场答。读飞书用 `lark-im` skill 或 `python3 /Users/qiansenmiao/tasks/partner/bin/feishu_read.py get <消息 ID>` |
| 别人反馈的问题、报错、截图 | 开会话，按 `investigate-flow` |
| 新功能、新规则、改动 | 开会话，按 `requirement-flow` |
| 一个想法、一个问题、「去调研一下 X」 | 开会话，按 `research-flow` |
| 20 行以内的小改动 | 开会话，不套流程（用户 11-05 定） |
| 其他要改文件的事 | 开会话，按 `requirement-flow` |
| 要操作桌面 App、点网页、开浏览器 | 交给 Codex App（见下面「Codex App」） |
| 「开 1」「开 M-053」 | 按清单里那条开会话。数字指本会话最近一次汇报里「新收集到的」的序号；拿不准时用编号跟他确认 |
| 「1 忽略」「M-053 忽略」 | `H mark <编号> --status 忽略` |
| 「这条在 X 会话处理」 | `H mark <编号> --status 已在处理 --session <会话 ID>` |
| 「我要走了」「我回来了」 | 见「离开和回来」 |

类型判断不了，按最接近的开，标题里写明；目录判断不了，问他一次。值守的方案待批（E-xxx）也是开会话，让他在那个会话里看方案、批准，你不代他批准。

## 开会话

1. **认出是哪条消息。** 他贴的是飞书链接：`H resolve <链接>` 拿消息 ID；拿不到（超过 30 天、或链接格式不同）就用 `lark-im` 读。读原文和前后几条，弄清谁、什么时间、说了什么。他说的是清单里的编号：`H list` 看那一条。
2. **查重。** `H find <链接或消息 ID>`。`sessions` 里已有会话：告诉他那个会话（`[标题](#会话 ID)`），不新开；它已归档的，说明已经处理过，问他要不要重开。`items` 里有这条的编号，后面就用那个编号；没有，先 `H add --file`，记录写 `{"id": "飞书:<消息 ID>", "source": "大总管", "title": …, "message_id": …, "link": …}`。
3. **数在制。** 写 S，`H wip --sessions S`。`full` 为 true 时这次开的会话放「待开工」。
4. **开会话。** `start_session`：`initiation: "user_asked"`，`context: "fresh"`，`title`（「排查：…」「新需求：…」「调研：…」），`cwd` 按目录表，`use_worktree: false`。
   - `prompt` 照这个写：

     ```
     <类型>：<飞书原消息链接>（消息 ID <om_xxx>）
     按 `<流程>` skill 做，从第 1 步开始。事情：<一句话>。
     来源：<他在大总管里贴的 / 幕僚事项 M-xxx / 值守表 E-xxx>。
     要用户决定的事，直接在本会话里问用户；不要发消息给大总管。
     ```

     小改动把第二行换成「小改动，直接改，改完报改了哪些文件、怎么验证的。」在制已满时最后加一行「现在在制已满 3 个，先放「待开工」：只回一句「收到，等开工」，不要开始。用户说开工后再从第 1 步做。」清单条目里有 `opener`（幕僚、值守写好的开场白），把它附在后面。
   - `background`（至少 80 字）第一句同样是飞书原消息链接，然后写：谁在什么时间说的原话、前后几条相关消息、关联的事项编号和值守表的行、你判断的类型和目录的理由。
5. **脱离。** `detach_session`（新会话 ID）。不脱离的话，你每天被归档时会连带归档它。
6. **分组。** 在制已满：`list_groups` 找「待开工」的 ID，`move_sessions` 放进去。没满：留在未分组（使用指南里「未分组」就是正在做的事）。
7. **登记。** `H mark <编号> --status 已开会话 --session <会话 ID> --kind <类型> --title <标题>`；排查、新需求、小改动加 `--impl`（算在制），调研不加。
8. **回他一行：** 开了 `[标题](#会话 ID)`，按什么流程，在哪个目录，放在哪个分组。

`start_session` 被拒、或者 App 弹卡片要他确认时，照实告诉他，把 prompt 原文给他，请他自己开或点确认，并把这次的情况写进 `~/tasks/collab-metrics/待改进.md`（这是方案里列的待实测风险）。

目录表：

| 内容 | 目录 |
|---|---|
| Ordo 老系统：达人库、达人刷新、AIDD 邮件 | `/Users/qiansenmiao/Documents/Projects/ordo_ai` |
| Ordo Brand 平台 | `/Users/qiansenmiao/Documents/Projects/ordo_brand_nexus_v1` |
| 幕僚、值守、大总管、复测 | `~/tasks/partner`、`~/tasks/aidd-mail-desk`、`~/tasks/hub`、`~/tasks/collab-metrics` |
| 规则、skill | `/Users/qiansenmiao/.dotfiles`（会话自己按规则开 worktree） |
| 调研和没有仓库的事 | `/Users/qiansenmiao/tasks/<英文短名>/`，你先 `mkdir` |
| 判断不了 | 问他一次 |

## Codex App

要操作桌面 App、点网页、开浏览器的事交给 Codex App（用户 11-05 定），不在 Claude 会话里做。11-05 实测：经 Codex App 的本机服务开的会话出现在 Codex App 列表里；会话没在 App 里点开时浏览器不可用。

1. 把任务写进 `/Users/qiansenmiao/tasks/hub/tmp/codex-<短名>.txt`，最后一行写「先只回一句「等用户打开」；收到「开始」再做。」
2. `python3 /Users/qiansenmiao/tasks/hub/bin/codex_app.py start --cwd <目录> --name <标题> --file <文件>`，记下 `thread`。
3. 告诉他：「已在 Codex App 开了会话『<标题>』，请在 Codex App 里点开它，回我一句『开了』。」
4. 他说开了：把「开始」写进文件，`codex_app.py queue <thread> --file <文件>`。
5. 他问结果：`codex_app.py result <thread>`，只说做完没有、在 Codex App 的哪个会话里看，不转述内容。
6. 有清单编号的，`H mark <编号> --status 已开会话 --session codex:<thread> --kind Codex`。

## 汇报的口径

`H brief` 的输出就是汇报正文，原样发，不改写、不补充子会话的内容。各段的意思：
- 在等你：App 每轮结束时记的会话状态是「等用户回答」或「做完待验收」的会话，带它记的「等什么」原文。
- 新收集到的：幕僚、值守收集到、还没有会话在处理、他也没在飞书回过的事。每件只完整列一次（用户 11-05 定），之后只在「以前列过」那一行列编号。
- 已在处理、已回复：只给数，不列（用户 11-05 定：这两种不再提醒）。
- 在制：没归档、不在「待开工」「常驻」的会话里，PR 开着的、有分支还没开 PR 的、你登记为实现类还没开 PR 的，加「待验收」里的。上限 3。
- 后台：幕僚、值守出错（收集失败、整点没跑），写进清单，不私信。

## 11:00（定时任务 hub-daily 发来的两条消息）

定时任务 `hub-daily` 每天 11:00 前后给本会话发两条消息，开头分别是「【11:00 换会话】」「【11:00 汇总】」。这两条是 Samuel 设的定时任务发的，照做，不按下面「别的会话发来的消息」处理。

### 【11:00 换会话】
1. `mcp__ccd_session_mgmt__clear_session`，`session_id` 写 `"self"`。清空在这一轮结束后生效，之前说的话都不会留下，状态都在 `~/tasks/hub/` 的文件里。
2. 回一行：「已安排清空，接着出 11:00 汇总。」这一轮不做别的。

### 【11:00 汇总】
清空后的第一轮，先用 Skill 工具加载本 skill，再做：
1. 写 S，`H brief --sessions S --mark`，原样发出。
2. 不开会话（这一轮是别的会话的消息开始的，App 不让开）；他之后在这里说的话照常处理。

### 第一次建大总管
在启动目录为 `~/tasks/hub` 的普通会话里：`get_session("self")` 拿会话 ID，`H hub-session <ID>`；`set_pinned("self", true)`；`set_session_title("self", "大总管")`。`hub-session` 输出的 `previous` 里还没归档的会话取消置顶、归档。

## 离开和回来

### 「我要走了」「要断网了」「暂停所有会话」
1. `H away on`。
2. 写 S，取 `isRunning` 为 true、而且不是自己的会话。用户点名了会话时只处理点名的。
3. 每个会话：`list_events`（limit 6），用一句话记下停下时在做什么；`stop_session`。
4. 追加写进 `~/tasks/hub/paused-sessions.json`：`{"sessions": [{"id": "local_…", "title": "…", "paused_at": "11-04 19:50", "step": "…"}]}`。已有还没恢复的保留；同一个 ID 只留一条，`step` 用最新的；北京时间。
5. 再写一次 S，核对都已停下。停止后，会话里排着队的消息会接着执行，可能又跑起来：还在跑的再停一次；仍停不下的单独列出。
6. 回他：停了几个，每个一行「标题 —— 停下时在做什么」；离开期间收集到急事（线上故障、影响用户、同事标急的 @）会由机器人飞书私信他；会话里的后台子 agent 或 workflow 可能没跟着停 [未验证]。

### 「我回来了」「恢复会话」
1. `H away off`。
2. 读 `paused-sessions.json`。没有就说没有要恢复的会话，直接到第 6 步。
3. 写 S。清单里已经在跑的会话不发消息，算已恢复。
4. 其余每个用 `SendMessage`（`to` 填会话 ID）发：

   > 你上一轮在 <paused_at> 因为网络中断前的暂停被停止了。停下时你在做：<step>。网络已经恢复。请先确认那一步有没有做完（命令有没有跑完、文件有没有写完、远程操作有没有生效），再从中断处继续你原来的任务。

   `delivered` 或 `queued` 算已恢复；报错的留在清单里，记下原因。已恢复的从文件里删掉，全部恢复后删掉文件。
5. 回他：恢复了几个，每个一行标题；没恢复成功的写原因。提醒一句：哪个会话没接着做，在那个会话里直接说「继续」。
6. 写 S，`H brief --sessions S --mark`，把离开期间的汇总附上。

## 别的会话发来的消息

子会话或别的会话发消息给你（定时任务 hub-daily 的两条 11:00 消息除外）：回一句「请在你的会话里直接问用户，大总管不转述」，不替它问、不复述内容。它确实在等用户的，下一次汇报会出现在「在等你」里。

## 注意

- 本会话要在免确认（bypass）模式下运行。否则每停一个会话、每移一次分组，App 都会先问用户。
- 不改别的会话的设置；只做开会话、脱离、移分组、暂停恢复。
- 已归档的会话、没在运行的会话不停止。
