# Postmortem: Lane 分轨方案审查到实施的全流程复盘

**日期**: 2026-03-20
**项目**: ordo_ai data-center (scheduler/dispatcher/enrichment)
**严重程度**: 中

## 时间线

### 方案审查阶段
1. 用户提供 `realtime_bulk_lane_design.md` 方案文档
2. 派 4 个 Researcher Agent 并行验证方案声明 → 全部与代码吻合
3. 输出 12 个审查意见（4 P0 / 4 P1 / 2 P2 / 2 P3）
4. Codex 独立 review + 交叉审查 → 新发现 3 个问题（derive/image 无 lane、NOT NULL 二进制兼容、Phase 切分违反镜像原则）
5. 合并去重：15 个问题

### 计划编写阶段
6. 写 20 个 Task 的实施计划
7. Codex review 计划 → **Needs revision**，发现 7 个问题：
   - derive/image 写库 upsert SQL 没改
   - getTaskForUpdateTx 不读 lane
   - video_detail batch_id 不是 enrich_ 前缀（不能用前缀猜 traffic source）
   - blocked 状态影响面被低估
   - Phase 3/4 顺序错误
   - Task 17 文件范围不够
   - 回滚方案自相矛盾
8. 逐一修复 7 处 → Codex 未再 review 计划（直接进入实施）

### 实施阶段
9. Task 1-5 顺利完成（shorts bug + lane 定义 + migration）
10. Task 6-7 并行派 Worker Agent → 成功，但 Task 6 工作量巨大（163 tool uses, 20min）
11. Task 8-12 陆续完成
12. Codex final review → **Needs revision**，4 个 Blocker：
    - **Blocker 1**: CreateTask 没自动推导 lane（所有 task 落 bulk.ctrl）
    - **Blocker 2**: lane 没透传到 result/derive/image jobs
    - **Blocker 3**: InitProducer 没读 lane topic 环境变量
    - **Blocker 4**: lane 模式无全局 in-flight 预算，可能超发
13. 修复 Blocker 1+4 和 2+3 各派一个 Agent 并行
14. Codex round 2 review → **仍 Needs revision**：
    - derive upsert 不更新 pending/running 的 lane
    - high_ video_detail 落 bulk.heavy 而非 rt.heavy
15. 手动修复 3 处（resolveLane 加 high_、derive upsert rt 覆盖 bulk、batchToLane 加 high_）
16. Codex round 3 → **LGTM**
17. 部署 test → 6 个服务全部 RUNNING，冒烟通过

## 根因分析

### 表面原因
Codex 3 轮 review 才 LGTM，实施阶段反复返工。

### 根本原因

**1. "基础设施先行"策略导致数据链路断裂**
Phase 1 计划的策略是"先加 lane 字段和查询支持，后续 Phase 再设置正确的 lane 值"。这导致所有 task/job 创建点都用 `lane.Default`（bulk.ctrl），lane 字段存在但数据全是错的。Codex 正确指出：这不是"后面再改"的问题，而是开关打开时会立即出 bug。[推断]

**2. 并行 Agent 对同一代码库的理解不完整**
Task 6 Agent 改了 model 层的 struct 和 INSERT/Scan，但对"谁调用这些函数"的理解不完整——它用 `lane.Default` 硬编码了所有调用点，而不是从上下文传入正确的 lane。这需要 Orchestrator 在指令中更明确地要求"从源头传递 lane"。[推断]

**3. video_detail batch_id 前缀歧义**
`high_` 前缀既用于 enrichment（高优先级）又用于 compensation（补偿），但 `resolveLane` 初始只识别 `enrich_`。这是因为 batch_id 命名规范没有 traffic class 语义——它是业务优先级标记，不是流量分类标记。[局部推断]

### 系统性因素

**1. 缺少端到端数据流测试**
单元测试验证了各模块的 SQL/Scan 正确性，但没有"创建 task → 发布 Kafka → 收到结果 → 创建 derive_job → 检查 lane 值"的集成测试。Codex 每轮都在指出"链路没打通"。

**2. 方案和实施计划的 Phase 切分过于乐观**
"Phase 1 只加字段，Phase 2 设置正确值"这种拆分在 review 时被反复质疑。实际上 Phase 1 如果不能在开关打开时正确工作，就不是一个独立可验证的阶段。

**3. batch_id 前缀承载了过多语义**
`enrich_`, `comp_`, `high_`, `recrawl_`, `pipeline_` — batch_id 前缀既决定优先级、又决定 traffic class、还决定是否被 dispatcher 管理。这种 "名字即配置" 的模式容易遗漏。

## 教训

### 1. 数据链路变更必须端到端验证，不能分段交付

**规则**: 新增持久化字段（如 lane）时，不能只改 model 层"加字段 + 默认值"就算一个阶段完成。必须在同一阶段确保所有写入点写入正确值，并有从源头到终点的集成测试。

**适用场景**: 任何涉及"新字段贯穿多张表"的变更。

**违反后果**: Codex 3 轮 review，每轮都在指出"lane 数据链路没打通"。如果没有 review 直接部署并开启 feature flag，所有 task 都会落错 lane，dispatcher 行为错误。

### 2. batch_id 前缀不可靠作为 traffic class 判断依据

**规则**: 当需要新的分类维度（如 traffic class）时，应该显式传参或在持久化字段中记录，而不是从已有字段（如 batch_id 前缀）推导。推导容易遗漏新前缀或歧义前缀。

**适用场景**: data-center 中任何依赖 batch_id 前缀做决策的逻辑。

**违反后果**: `high_` 前缀的 video_detail 被错误分到 `bulk.heavy` 而非 `rt.heavy`。发现这个问题花了 2 轮 review。

### 3. 给并行 Agent 的指令必须包含"调用链完整性"要求

**规则**: 当 Agent 修改函数签名时，指令中必须明确要求"搜索所有调用点，确保传入正确的业务值而非 placeholder"。仅说"修复编译错误"会导致 Agent 用默认值填充。

**适用场景**: 任何涉及函数签名变更 + 多调用点的 Agent 任务。

**违反后果**: Task 6 Agent 用 `lane.Default` 填充了所有 derive_job 调用点，Blocker 2 在第一轮 review 才被发现。

## 行动项

- [x] 修复所有 Codex review 发现的问题（3 轮，全部修复）
- [x] 部署到 test 环境，冒烟通过
- [ ] 补充端到端集成测试：enrich task 创建 → lane=rt.* → result_job → derive_job → image_job 全链路 lane 传递
- [ ] 考虑给 batch 表加显式 `traffic_class` 字段，替代 batch_id 前缀推导
- [ ] Phase 2 实施前，先把 DISPATCHER_LANE_ENABLED=true 在 test 跑一轮完整 enrich 验证
