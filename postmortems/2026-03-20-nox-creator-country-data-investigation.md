# Postmortem: Nox 导入达人 country 数据异常排查

**日期**: 2026-03-20
**项目**: ordo-backend (ordo_ai_debug)
**严重程度**: 中

## 背景

Nox 导入了 220,571 个达人（Instagram 48,480 + TikTok 158,326 + YouTube 13,765），JSON 源文件中 country 几乎全部为 "UK"（220,228 条），少量为 "GB"（251 条）。用户发现 DB 中 Instagram 达人的 country 数据有缺失/变化。

## 时间线

1. **问题发现**: 用户注意到 DB 中 INS 达人的 country 不对
2. **脚本排查**: 找到 `ig-backfill/main.go`（Apify 补数据脚本）和 `import_nox_creators.go`（Nox 导入脚本），确认导入时 country 字段是正确带入的
3. **写入路径穷举**: 排查所有 `UPDATE ordo_creators` 的代码路径（约 30+ 处），逐一分析是否涉及 country 字段：
   - `ig-backfill`: UPDATE 不含 country 字段 — 安全
   - `field_updater.go` (data-center user sync): 仅非空才更新 — 安全
   - `UpsertCreatorBasic`: `IF(VALUES(country)!='', ...)` 保护 — 安全
   - `admin_import_handler.go`: **blanket SET country = ?** — 唯一可清空 country 的路径
4. **数据验证**: 导出 country='UK' 的 192,087 条达人 → 修正为 'GB' + DashVector 入队
5. **差异分析**: INS 文件 48,480 vs uk_creators 44,324 = 差 4,156 个。其中 238 个原本就是 GB，**3,918 个 country 在 DB 中已被改变**
6. **3,918 个达人的 DB 实际状态**:
   - 全部仍在 DB 中（未丢失）
   - country 分布：GB 2,196 | ZZ 887 | 空 326 | 其他国家 509
   - 结论：被 data-center 爬虫的后续 sync 覆盖了（爬虫返回了新 country 值）

## 根因分析

- **表面原因**: INS 达人的 country 从 "UK" 变成了 GB/ZZ/空/其他国家
- **根本原因**: 多条数据写入路径对 country 字段的处理策略不一致：
  - `field_updater.go` 有"非空才覆盖"保护 → 不会清空，但会用爬虫返回的非空值覆盖
  - `admin_import_handler.go` 无保护 → 可以用空值覆盖
  - Nox 源数据用 "UK" 而非 ISO 标准 "GB" → 本身就是数据质量问题
- **系统性因素**:
  1. 导入源数据未做标准化（UK vs GB），Nox 用非 ISO 国家代码
  2. `admin_import_handler` 的 blanket UPDATE 未对空值做保护，与其他路径（field_updater、UpsertCreatorBasic）的防御策略不一致
  3. country 字段没有枚举校验（允许 "UK"、"ZZ" 等非标准值写入）

## 关键发现

### 写入路径安全性总表

| 路径 | 涉及 country | 空值保护 | 风险 |
|------|-------------|---------|------|
| import_nox_creators.go | INSERT IGNORE | N/A（仅插入） | 无 |
| ig-backfill/main.go | 不涉及 | N/A | 无 |
| field_updater.go (user sync) | 仅非空更新 | 有 | 低（会被爬虫覆盖） |
| UpsertCreatorBasic | IF 条件保护 | 有 | 低 |
| import_result_handler.go | 仅非空更新 | 有 | 低 |
| **admin_import_handler.go** | **blanket SET** | **无** | **高** |

### DashVector 同步

- sync-queue 模式通过 `ordo_creator_embedding_queue` 入队触发，不是清 sync_hash
- 入队时 `requested_at` 用早时间戳可实现高优处理（队列按 requested_at ASC claim）
- country 字段在所有 content type（videos/reels/shorts/posts）的 DashVector 集合中都有

### 数据修复执行

- 编写 `scripts/fix_country_uk_to_gb.go`，两阶段：Phase 1 查询存文件 → Phase 2 读文件精确更新
- 通过 OSS 传二进制到 prod 执行（本地无法直连 prod RDS）
- 192,087 条 UK→GB 更新 + DashVector 入队，58 秒完成

## 教训

### 1. 批量写入路径必须对可选字段做空值保护
- **规则**: 所有 UPDATE 语句涉及可选字段（country/language/bio 等）时，必须用 `IF(? != '', ?, field)` 或代码层 "非空才加入 SET" 模式
- **适用场景**: 任何新增或修改涉及 ordo_creators 写入的代码
- **违反后果**: 空值静默覆盖有效数据，且难以追溯

### 2. 外部数据导入必须做字段标准化
- **规则**: 导入第三方数据时，国家代码统一用 ISO 3166-1 alpha-2（GB 而非 UK），在导入脚本中做 mapping
- **适用场景**: 所有从 Nox、Modash 等外部数据源导入的流程
- **违反后果**: 非标准值进入 DB 后扩散到 DashVector、搜索等下游系统

### 3. DashVector 同步方式取决于运行模式
- **规则**: 全量扫描模式 → 清 sync_hash 触发；sync-queue 模式 → 往 `ordo_creator_embedding_queue` 入队触发。当前 prod 运行的是 sync-queue 模式
- **适用场景**: 任何需要触发 DashVector 重同步的脚本
- **违反后果**: 清了 sync_hash 但数据不会被重新同步

## 行动项

- [x] 修复 192,087 条 country UK→GB
- [x] DashVector 入队同步（高优）
- [ ] 修复 `admin_import_handler.go` 的 blanket UPDATE，加空值保护（与 field_updater 对齐）
- [ ] 处理 3,918 个被覆盖的达人（326 个空值 + 887 个 ZZ 需决策是否回写 GB）
- [ ] 考虑在 DB 层或应用层加 country 枚举校验（禁止 UK/ZZ 等非标准值）
