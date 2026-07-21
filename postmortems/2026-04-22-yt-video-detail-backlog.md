# 2026-04-22 YT video_detail 积压排查：10+ 轮跳跃式假说

## 事实

- 排查过程出现 10+ 轮跳跃式假说、3 处关键事实错位：
  1. `received_at` 的实际 writer 是 ingester 而非 worker（凭符号名猜的）
  2. refresh "batch write" 的代码注释自己写明是 sequential，未读实现就当作批量
  3. 提议降 `DISPATCHER_PENDING_TIMEOUT_MIN` 会触发 `ExpireBatchTasks` 批量误杀活跃任务
- 被反问就跳新假说，而不是稳住事实锚点追问原假说为什么不成立

## 根因

不读实现只看符号名 / 不做对照组 / 假说不带证伪测试。

## 沉淀的规则

- `pipeline-debug-protocol` skill：事实地图先行、假说必带证伪测试、对照组 diff、时间戳字段先 grep 所有写入点、"谁写/谁读/谁触发"断言必须带 file:line
- `debugging-discipline` skill：假说收敛纪律（被反问稳住当前假说追到底）
