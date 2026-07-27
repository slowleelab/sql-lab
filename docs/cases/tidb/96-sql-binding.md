# SQL Binding 执行计划锁定 (SPM)

<CaseMeta difficulty="⭐⭐⭐" category="TiDB 分布式优化" versions="TiDB" :tags="['SPM', 'SQL Binding', '执行计划', 'Baseline', 'Plan Management', 'Hint']" />

## 场景痛点

你在负责一个电商系统的订单查询服务。大促期间，运营同学突然反馈"订单列表页加载超时"。你打开 Grafana 监控，发现一条核心查询的 P99 延迟从平时的 50ms 飙升至 3 秒。你迅速找到对应的 SQL：

```sql
SELECT * FROM t_spm_test
WHERE status = 1 AND city = 'Beijing'
ORDER BY created_at DESC
LIMIT 20;
```

查看慢查询日志中的 EXPLAIN，发现这条 SQL 的执行计划从 **IndexLookUp（走 idx_status 索引）** 变成了 **TableFullScan（全表扫描 + Sort）**。你回忆起：两小时前 TiDB 自动执行了 `ANALYZE TABLE`，统计信息的直方图边界发生了细微变化。优化器根据新的统计信息重新估算：`status=1` 覆盖 90% 的数据，走索引需要回表 27 万次，不如全表扫描划算——于是毅然选择了全表扫描。

但这在业务上是灾难性的：全表扫描 30 万行 + 排序，在高并发下直接打满 TiKV CPU，整个集群的服务质量都受到影响。

```sql
-- EXPLAIN 显示全表扫描（优化器选错计划）
+------------------------------+----------+-----------+--------------------------------+
| id                           | estRows  | task      | access object                  |
+------------------------------+----------+-----------+--------------------------------+
| TopN_8                       | 20.00    | root      |                                |
| └─TableReader_14             | 17100.00 | root      |                                |
|   └─Selection_13             | 17100.00 | cop[tikv] |                                |
|     └─TableFullScan_12       | 270000.00| cop[tikv] | table:t_spm_test               |
+------------------------------+----------+-----------+--------------------------------+
```

::: warning 真实场景

某金融支付平台的核心交易查询在一次 TiDB 版本升级后，20% 的 SQL 执行计划发生了"突变"——其中 3 条核心 SQL 因计划变差导致 P99 延迟从 10ms 变为 2s。DBA 紧急使用 `CREATE GLOBAL BINDING` 锁定了升级前的执行计划，5 分钟内恢复了服务质量。事后分析，新版本优化器对"LIMIT 小值 + 大范围扫描"场景的成本模型有所调整。

:::

**本质问题**：优化器基于统计信息和成本模型做决策，但成本模型是"模拟"而非"真实"——当统计信息偏差、版本升级或数据分布变化时，优化器可能选错计划。在生产环境中，**执行计划的不确定性本身就是风险**。

## 问题分析

### TiDB 优化器的执行计划选择过程

```
SQL 文本
    │
    ▼
① SQL 解析 → AST（抽象语法树）
    │
    ▼
② 逻辑优化
   ├─ 列裁剪（只保留需要的列）
   ├─ 谓词下推（WHERE 条件下推到 TiKV）
   ├─ TopN/Limit 下推
   └─ 子查询展开 / 连接重排
    │
    ▼
③ 统计信息估算
   ├─ 查询 mysql.stats_meta（行数、修改数）
   ├─ 查询 mysql.stats_histograms（直方图边界）
   └─ 计算每个候选索引的 rows_est（预估扫描行数）
    │
    ▼
④ 物理优化（成本模型）
   ├─ 枚举所有可能的访问路径
   ├─ 对每个路径计算 CPU + I/O + 网络总成本
   └─ 选择 cost 最低的计划
    │
    ▼
⑤ 生成最终执行计划 → 执行
```

**问题出在第 ③-④ 步**：当统计信息存在偏差（常见于数据分布不均的表），优化器的成本估算会偏离实际。例如本例：

- `status=1` 占 90%（270,000/300,000），优化器认为用 `idx_status` 需要回表 27 万次
- `city='Beijing'` 占约 10%（30,000/300,000），但 `idx_city` 过滤后仍需处理 status 和排序
- 优化器的"理性选择"：全表扫描 30 万行（顺序读）比 27 万次随机回表更便宜
- **但优化器忽略了**：LIMIT 20 意味着一旦找到 20 条匹配行就可以提前终止——实际回表量远小于 27 万

### bad.sql：无 Binding 时优化器可能选错

核心问题在 `EXPLAIN` 的 `access object` 列：`table:t_spm_test`（全表扫描），而非 `index:idx_status`（索引扫描）。对于 300K 数据的表这不是灾难，但如果是 3000 万行的生产表，全表扫描的代价就是数十秒的阻塞。

同时 `SHOW GLOBAL BINDINGS` 返回空集——没有任何"安全网"来防止执行计划突变。

## 优化方案

### good.sql：CREATE GLOBAL BINDING 锁定计划

**核心思路**：不修改应用代码，在数据库层为 SQL 模板绑定一个带 Hint 的执行计划。TiDB 在执行原始 SQL 时自动匹配 Binding 并注入 Hint。

```sql
-- 步骤 1: 创建绑定（DBA 操作，应用无感知）
CREATE GLOBAL BINDING FOR
  SELECT * FROM t_spm_test WHERE status = 1 AND city = 'Beijing' ORDER BY created_at DESC LIMIT 20
USING
  SELECT /*+ USE_INDEX(t_spm_test, idx_status) */ * FROM t_spm_test WHERE status = 1 AND city = 'Beijing' ORDER BY created_at DESC LIMIT 20;

-- 步骤 2: 确认绑定已生效
SHOW GLOBAL BINDINGS;
-- 返回一行：original_sql → bind_sql（带 USE_INDEX hint）

-- 步骤 3: EXPLAIN 验证计划已改变
EXPLAIN SELECT * FROM t_spm_test WHERE status = 1 AND city = 'Beijing' ORDER BY created_at DESC LIMIT 20;
-- access object 变为: index:idx_status, range:[1,1]
```

执行后 `EXPLAIN` 的输出：

```
+------------------------------+----------+-----------+------------------------------------+
| id                           | estRows  | task      | access object                      |
+------------------------------+----------+-----------+------------------------------------+
| TopN_8                       | 20.00    | root      |                                    |
| └─IndexLookUp_7              | 20.00    | root      |                                    |
|   ├─IndexRangeScan_5(Build)  | 270000.00| cop[tikv] | table:t_spm_test, index:idx_status  |
|   └─Selection_6(Probe)       | 2.70     | cop[tikv] |                                    |
|     └─TableRowIDScan_7       | 270000.00| cop[tikv] | table:t_spm_test                   |
+------------------------------+----------+-----------+------------------------------------+
```

`access object` 从 `table:t_spm_test`（全表扫描）变为 `index:idx_status, range:[1,1]`（索引范围扫描）——计划已被 Binding 强制锁定。

### Binding 的匹配机制

Binding 并非简单做 SQL 字符串匹配。TiDB SPM 的匹配流程：

```
① 归一化 SQL：移除多余空格、统一大小写、参数化常量 → 生成 SQL_DIGEST
② 在 bind_info 表中查找 (SQL_DIGEST, default_db, status='enabled') 匹配的 Binding
③ HIT → 从 bind_sql 提取 Hint → 注入优化器上下文 → 按 Hint 生成计划
④ MISS → 优化器自主选择计划（普通流程）
```

**关键特征**：常量值被参数化。 `status = 1` 和 `status = 2` 命中同一 Binding，因为参数化后模板相同。

### 紧急止血流程

```
生产故障发生：
  大促期间 SQL 突然变慢
       │
       ▼
  ① EXPLAIN 确认计划异常（全表扫描代替索引扫描）
       │
       ▼
  ② 找到最优执行计划（用 EXPLAIN + Hint 模拟）
     EXPLAIN SELECT /*+ USE_INDEX(t_spm_test, idx_status) */ ...
       │
       ▼
  ③ CREATE GLOBAL BINDING 锁定计划（秒级生效）
       │
       ▼
  ④ 确认延迟恢复（Grafana P99 回落）
       │
       ▼
  ⑤ 事后分析根因：
     - 统计信息是否偏差？（SHOW STATS_HEALTHY）
     - 数据分布是否变化？
     - 是否需要添加复合索引根治？
```

## 深入原理

### SPM（SQL Plan Management）架构

TiDB SPM 的架构分为三层：

```
┌─────────────────────────────────────────────────────────────┐
│                    SPM 管理层                                │
│  CREATE/DROP GLOBAL BINDING                                  │
│  SHOW GLOBAL BINDINGS                                        │
│  information_schema.bind_info                                │
└──────────────────────┬──────────────────────────────────────┘
                       │
┌──────────────────────▼──────────────────────────────────────┐
│                    SPM 匹配层                                │
│  ① SQL Digest 计算（参数化 + 哈希）                            │
│  ② bind_info 查找（digest + db + status）                     │
│  ③ Hint 提取与注入（合并到优化器上下文）                         │
└──────────────────────┬──────────────────────────────────────┘
                       │
┌──────────────────────▼──────────────────────────────────────┐
│                   优化器执行层                                │
│  ① Hint 上下文优先级 > 优化器默认行为                          │
│  ② 按 Hint 指定的策略做物理优化                                │
│  ③ 生成最终执行计划                                           │
└─────────────────────────────────────────────────────────────┘
```

### Binding 的存储

Binding 信息存储在 `mysql.bind_info` 系统表中：

```sql
SELECT original_sql, bind_sql, default_db, status, source, create_time
FROM mysql.bind_info;
```

| 字段 | 说明 |
|------|------|
| `original_sql` | 原始 SQL（参数化后，常量替换为 `?`） |
| `bind_sql` | 绑定 SQL（含 Hint 的计划指示） |
| `default_db` | 数据库上下文 |
| `status` | `enabled` / `disabled` / `deleted` |
| `source` | `manual`（手动创建）/ `evolve`（自动演进）/ `import`（导入） |
| `create_time` | 创建时间 |
| `update_time` | 最后修改时间 |
| `sql_digest` | SQL 模板的哈希指纹 |
| `plan_digest` | 绑定计划的哈希指纹 |

### Binding vs Hint 对比

| 维度 | SQL Hint | SQL Binding (SPM) |
|------|---------|-------------------|
| 生效方式 | 需要修改 SQL 文本 | **无需修改 SQL**，自动匹配注入 |
| 应用代码侵入 | **需要改代码**（加 Hint 注释） | **零侵入**，DBA 在数据库层操作 |
| 生效速度 | 需要走发布流程（分钟~小时） | **秒级生效**（CREATE BINDING 即时生效） |
| 回滚方式 | 重新发布（去掉 Hint） | `DROP GLOBAL BINDING`（秒级回滚） |
| 管理视图 | 散落在各服务代码中 | **集中在 bind_info 表** |
| 自动演进 | 不支持 | **支持 Evolve 自动发现更优计划** |
| 版本兼容 | Hint 语法一般向后兼容 | **Binding 不跨版本保证有效** |
| 参数化匹配 | 一个 Hint 只对应一条具体 SQL | **一个 Binding 覆盖所有常量的同模式 SQL** |

### Evolve：Binding 的自动演进

手动创建的 Binding 锁定了计划，但也锁死了优化器发现更优方案的可能。Evolve 机制解决了这个矛盾：

```
启动条件: SET GLOBAL tidb_enable_plan_replayer = ON;

① 后台任务定期（默认 30min）扫描所有 enabled 的 Binding
       │
       ▼
② 对每个 Binding 尝试"脱 Hint 重新优化"
   → 如果优化器发现 cost 更低的替代计划
       │
       ▼
③ 影子执行验证
   ├─ 在生产流量中以极低比例（默认 1%）执行新计划
   ├─ 收集新计划的 P99 延迟、资源消耗
   └─ 与当前绑定计划的指标对比
       │
       ├─ 新计划更优 → 自动更新 bind_sql 并记录为 source='evolve'
       │   （稳妥策略：生成 evolve 任务等待 DBA 审核）
       │
       └─ 新计划更差 → 静默丢弃
```

```sql
-- 查看 evolve 状态
SELECT * FROM mysql.bind_info WHERE source = 'evolve';

-- 手动接受 / 拒绝 evolve 结果
ADMIN EVOLVE ACCEPT TASK '<task_id>';
ADMIN EVOLVE REJECT TASK '<task_id>';
```

### Binding 的局限性

**Binding 不跨版本保证有效**：当 TiDB 升级后，某些 Hint 的语义可能发生变化，甚至被废弃。例如 TiDB v6.0 的 `HASH_JOIN_BUILD` 在 v7.0 可能不再支持； `READ_FROM_STORAGE` 的选项也可能随 TiFlash 版本而改变。升级前务必验证所有 Binding 仍然有效。

| 限制 | 说明 | 应对策略 |
|------|------|---------|
| **不跨版本保证** | TiDB 升级后 Hint 语义可能变化 | 升级前用 `SHOW GLOBAL BINDINGS` 导出清单，升级后逐条验证 |
| 不支持子查询 | 包含子查询的 SQL 无法创建 Binding | 考虑将子查询改写为 JOIN |
| 不支持 DML | `INSERT/UPDATE/DELETE` 暂不支持 Binding | SPM 当前仅覆盖 SELECT |
| 精确文本匹配 | 多一个空格或换行不影响（归一化），但列顺序不同会视为不同 SQL | 保持 SQL 模板的一致性 |
| GLOBAL 作用域 | 目前仅支持 GLOBAL 级别（无 SESSION 级 Binding） | 所有连接共享同一 Binding 集合 |

### 复合索引 vs Binding 的选择

在 bad.sql 中，根本原因是表只有三个单列索引（`idx_status`、`idx_city`、`idx_created`），没有覆盖 `(status, city, created_at)` 的复合索引。如果业务允许 DDL 变更：

| 方案 | 优点 | 缺点 |
|------|------|------|
| **添加复合索引** `idx_status_city_created(status, city, created_at)` | 根治问题，优化器自然选择正确计划 | 需要 ONLINE DDL（会短暂影响写入）、额外存储空间 |
| **CREATE BINDING** | 秒级生效，零代码改动 | 治标不治本，不跨版本保证；依赖于 Hint 语法稳定性 |
| **复合索引 + Binding** | 复合索引根治 + Binding 兜底防退化 | 最佳实践，也是最推荐的生产策略 |

::: tip 核心认知

Binding 是"止血带"而非"手术刀"。它的价值在于**应急响应**（紧急锁定计划）和**安全网**（防止计划退化）。但长期的最佳实践仍然是：用合理的索引设计让优化器天然选对计划，用 Binding 作为"安全网"防止意外退化，用 Evolve 让计划随数据变化持续优化。

:::

## 本地复现

```bash
# 启动 TiDB 环境并执行案例
./scripts/run-case.sh 96-sql-binding --ver tidb
```

执行后观察：

- bad.sql 中 `SHOW GLOBAL BINDINGS` 返回空集（无绑定保护）
- bad.sql 的 EXPLAIN 输出中 `access object` 为 `table:t_spm_test`（全表扫描）
- good.sql 中 `CREATE GLOBAL BINDING` 创建后 `SHOW GLOBAL BINDINGS` 显示一条绑定记录
- good.sql 的 EXPLAIN 输出中 `access object` 变为 `index:idx_status`（索引扫描）
- `SHOW GLOBAL BINDING FOR ...` 显示绑定的原始 SQL 与带 Hint SQL 的对应关系
- `information_schema.bind_info` 中查看 Binding 的元数据（source, status, sql_digest）

::: warning 重要提示

复现时注意：
1. `CREATE GLOBAL BINDING` 中的 `FOR` 子句和 `USING` 子句必须是**完整的 SQL 语句**（含 SELECT 关键字），不能只写 WHERE 条件
2. SPM 对 SQL 做参数化匹配——`status = 1` 和 `status = 2` 共享同一 Binding，因为常量被归一化为 `?`
3. 如果表的统计信息恰好让优化器选择 idx_status，需要手动调整统计信息（或用 `ANALYZE TABLE ... WITH NUM BUCKETS` 减少直方图精度）来制造"选错计划"的场景
4. `DROP GLOBAL BINDING` 后计划恢复到优化器自主选择——没有"回退到上一个 Binding"的概念

:::

## 常见问题

**Q: Binding 和直接加 Hint 有什么区别？**

A: Hint 写在 SQL 文本中，需要修改应用代码并走发布流程。Binding 由 DBA 在数据库层创建，原始 SQL 不需要任何修改——TiDB 在优化时自动匹配 Binding 并注入 Hint。这使得 Binding 可以在故障发生时秒级止血，而不需要等代码发布。此外，一个 Binding 通过参数化匹配可以覆盖所有常量变体的 SQL（如 `status=1` 和 `status=2` 命中同一 Binding），而 Hint 只对写了它的那条 SQL 生效。

**Q: Binding 会不会导致"过时计划"？**

A: 有可能。当数据分布发生显著变化（如 status 分布从 90% 变为 10%），手动绑定的计划可能不再是最优解。Evolve 机制正是为解决这个问题而设计——它会在后台尝试脱 Hint 重新优化，如果发现更优计划，会生成 evolve 任务供 DBA 审核。建议定期检查 Evolve 建议，并在数据发生重大变更（如大促后批量更新状态）时验证 Binding 是否仍然有效。

**Q: 一条 SQL 可以绑定多个执行计划吗？**

A: 不可以。每个 SQL 模板（SQL_DIGEST + default_db）在同一时间只能有一个 `status='enabled'` 的 Binding。如果需要切换计划，需要先删除旧 Binding 再创建新的。Evolve 机制可以在不删除原 Binding 的情况下验证替代计划，但替代计划不会自动替代原 Binding——需要 DBA 手动审核和切换。

**Q: 如何找出"被优化器选错计划"的 SQL？**

A: 关注以下信号：(1) Grafana 中 P99 延迟突然飙升但 QPS 未变；(2) `STATEMENTS_SUMMARY` 中同一条 SQL_DIGEST 的 `AVG_PROCESS_TIME` 波动超过 3x；(3) 慢查询日志中出现"之前跑得快现在跑得慢"的 SQL；(4) `SHOW STATS_HEALTHY` 显示统计信息健康度低于 80%。发现后，用 `EXPLAIN` 对比当前计划和历史计划，确定是否发生了计划退化。

**Q: Binding 创建后是持久化的吗？TiDB 重启会丢失吗？**

A: Binding 存储在 `mysql.bind_info` 系统表中，是持久化的。TiDB 重启后不会丢失。无论集群滚动重启还是全集群停机，Binding 都会在 TiDB 重新启动后自动加载并生效。

**Q: 删除 Binding 后 SQL 会立即生效吗？**

A: 是的。`DROP GLOBAL BINDING` 是即时生效的 DDL 操作，删除后下一个匹配该 SQL 模板的查询就会走优化器的默认选择路径。不需要执行任何额外的刷新或重启操作。
