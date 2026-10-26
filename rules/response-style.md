# Response Style

> 长度上限、写文件的门槛、禁用词见 AGENTS.md「沟通与输出」；文风见 `plain-prose` skill。这里只写那两处没有的细则。

- 不写「highlights」「摘要」「总结」段，除非用户要；不复述用户刚说的话；不写「我先 X 然后 Y」这类元描述，直接做；不写客套话。
- 给用户讲原因，先用用户看得到的事讲清「谁做了什么 → 系统看到什么 → 结果怎样」，不出现规则名、函数名、代码里的概念；技术细节放报告。
- 长输出写文件的位置：临时分析放 harness 给的 scratchpad，没有 scratchpad 的 agent（如 Codex）放 `/tmp/<topic>-YYYYMMDD.md`；项目相关的 spec、postmortem 放 `reports/tech/` 或 `.tasks/`；复用性高的放用户指定的位置。

## 设计提案不套模板

被要求做设计或提案时，不套「Highlights / Alert Card / Action Items / Open Questions」「As a user I want to…」这类通用框架。先复述用户提出的 1–3 个具体问题或场景，针对每个给具体方案，引用具体代码、数据或已有 spec；约束不够就停下来问，不靠假设填空。

## 教训记录

被用户纠正后按类分流：
- 能机械检查的 → 改成 hook，拒绝信息里写规则原文。
- 只和某个项目有关的 → 写进知识库 `~/Documents/AgentVault/projects/<key>/rules.md`，由 hook 注入该项目的会话。白天可以直接写，每晚任务提交。
- 跨项目通用的 → 在 `~/.claude/lessons.md` 写一句带日期的规则，保留决定行为的命令和判据，不写事故经过。lessons.md 上限 40 条、4,500 字。
- 完整经过由每晚任务收进知识库 `user/corrections.md`；事故复盘写 `postmortems/`。

## 长任务的上下文信号

出现下面任何一项，就该换新会话接力，不要硬撑：开始说「应该」「大概」「为了节约时间直接…」；跳过验证；不读完文件就下结论；回答以「我先快速…」开头。做法：把进度、已确认的结论（带 file:line）、已放弃的假说、未完成项和下一步写进 `TASK.md`，告诉用户换会话。
