# EXPLAIN 参考结果 - good.sql（Binding 锁定执行计划）

## TiDB v7.5+（30 万行，status=1 占 90%）

---

### 1. CREATE GLOBAL BINDING

```sql
CREATE GLOBAL BINDING FOR
  SELECT * FROM t_spm_test WHERE status = 1 AND city = 'Beijing' ORDER BY created_at DESC LIMIT 20
USING
  SELECT /*+ USE_INDEX(t_spm_test, idx_status) */ * FROM t_spm_test WHERE status = 1 AND city = 'Beijing' ORDER BY created_at DESC LIMIT 20;
```

```
Query OK, 0 rows affected (0.05 sec)
```

`CREATE GLOBAL BINDING` 将原始 SQL 模板与带 Hint 的 SQL 模板建立了绑定关系。**即使原始 SQL 中没有 Hint，TiDB 在优化时也会自动注入 Hint 中指定的执行策略**。

---

### 2. SHOW GLOBAL BINDINGS（确认绑定已创建）

```sql
SHOW GLOBAL BINDINGS;
```

```
+-----------------------------------------------------------------------------+----------------------------------------------------------------------------------+
| Original_sql                                                                | Bind_sql                                                                         |
+-----------------------------------------------------------------------------+----------------------------------------------------------------------------------+
| SELECT * FROM `sql_treasure`.`t_spm_test`                                   | SELECT /*+ USE_INDEX(`t_spm_test` `idx_status`)*/ *                             |
| WHERE `status` = ? AND `city` = ?                                           | FROM `sql_treasure`.`t_spm_test`                                                 |
| ORDER BY `created_at` DESC LIMIT ...                                        | WHERE `status` = ? AND `city` = ?                                                |
|                                                                             | ORDER BY `created_at` DESC LIMIT ...                                            |
+-----------------------------------------------------------------------------+----------------------------------------------------------------------------------+
```

关键观察：

| 字段 | 说明 |
|------|------|
| `Original_sql` | 原始 SQL 模板——**常量已被参数化为 `?`** |
| `Bind_sql` | 绑定 SQL 模板——包含 `/*+ USE_INDEX(...) */` Hint |
| 参数化 | SPM 对常量值做归一化，不同常量值的同模式 SQL 共享同一 Binding |

---

### 3. SHOW GLOBAL BINDING FOR（查看绑定详情）

```sql
SHOW GLOBAL BINDING FOR
  SELECT * FROM t_spm_test WHERE status = ? AND city = ? ORDER BY created_at DESC LIMIT ?;
```

```
*************************** 1. row ***************************
  Original_sql: SELECT * FROM `sql_treasure`.`t_spm_test`
                WHERE `status` = ? AND `city` = ?
                ORDER BY `created_at` DESC LIMIT ...
     Bind_sql:  SELECT /*+ USE_INDEX(`t_spm_test` `idx_status`)*/ *
                FROM `sql_treasure`.`t_spm_test`
                WHERE `status` = ? AND `city` = ?
                ORDER BY `created_at` DESC LIMIT ...
Default_db: sql_treasure
    Status: enabled
Create_time: 2026-07-28 10:30:00.000
Update_time: 2026-07-28 10:30:00.000
    Charset: utf8mb4
    Collation: utf8mb4_bin
      Source: manual
```

| 字段 | 值 | 说明 |
|------|-----|------|
| `Status` | `enabled` | 绑定处于激活状态 |
| `Source` | `manual` | 手动创建的 Binding（非 evolve 自动生成） |
| `Default_db` | `sql_treasure` | 绑定所属数据库 |
| `Charset/Collation` | `utf8mb4` / `utf8mb4_bin` | SQL 模板的字符集和排序规则 |

---

### 4. EXPLAIN 验证：计划已锁定为 idx_status

```sql
EXPLAIN SELECT * FROM t_spm_test
WHERE status = 1 AND city = 'Beijing'
ORDER BY created_at DESC
LIMIT 20;
```

```
+------------------------------+----------+-----------+------------------------------------+----------------------------------------------+
| id                           | estRows  | task      | access object                      | operator info                                |
+------------------------------+----------+-----------+------------------------------------+----------------------------------------------+
| TopN_8                       | 20.00    | root      |                                    | t_spm_test.created_at:desc, offset:0, count:20 |
| └─IndexLookUp_7              | 20.00    | root      |                                    |                                              |
|   ├─IndexRangeScan_5(Build)  | 270000.00| cop[tikv] | table:t_spm_test, index:idx_status  | range:[1,1], keep order:false               |
|   └─Selection_6(Probe)       | 2.70     | cop[tikv] |                                    | eq(t_spm_test.city, "Beijing")               |
|     └─TableRowIDScan_7       | 270000.00| cop[tikv] | table:t_spm_test                   | keep order:false                             |
+------------------------------+----------+-----------+------------------------------------+----------------------------------------------+
```

| 字段 | bad.sql（无 Binding） | good.sql（有 Binding） | 变化 |
|------|----------------------|----------------------|------|
| 访问路径 | `TableFullScan` | **`IndexLookUp + IndexRangeScan(idx_status)`** | 强制走索引 |
| access object | `table:t_spm_test` | **`index:idx_status, range:[1,1]`** | 索引扫描替代全表扫描 |
| 驱动方式 | 全表扫描 + Selection | 索引范围扫描 + 回表 | **计划被 Binding 锁定** |

注意：即使 `EXPLAIN` 中显示 `USE_INDEX` Hint 的效果，**原始 SQL 中并没有写任何 Hint**——TiDB 在优化时自动匹配 Binding 并注入 Hint。

---

### 5. information_schema.bind_info（查看 Binding 元数据）

```sql
SELECT * FROM information_schema.bind_info
WHERE original_sql LIKE '%t_spm_test%'\G
```

```
*************************** 1. row ***************************
     original_sql: SELECT * FROM `sql_treasure`.`t_spm_test`
                   WHERE `status` = ? AND `city` = ?
                   ORDER BY `created_at` DESC LIMIT ...
        bind_sql: SELECT /*+ USE_INDEX(`t_spm_test` `idx_status`)*/ *
                  FROM `sql_treasure`.`t_spm_test`
                  WHERE `status` = ? AND `city` = ?
                  ORDER BY `created_at` DESC LIMIT ...
    default_db: sql_treasure
        status: enabled
   create_time: 2026-07-28 10:30:00
   update_time: 2026-07-28 10:30:00
       charset: utf8mb4
     collation: utf8mb4_bin
        source: manual
     sql_digest: 42a1c8aae6f133e9a1b2c3d4e5f6a7b8
 plan_digest: 92c3f3b6e1a0d5c7e8f9a0b1c2d3e4f5
```

---

### 6. Binding 的优先级与匹配机制

```
SQL 请求到达 TiDB
        │
        ▼
  ① 解析 SQL，计算 SQL_DIGEST
        │
        ▼
  ② 在 bind_info 表中查找匹配的 Binding
     ├─ 匹配条件:
     │   ├─ SQL_DIGEST 一致（参数化后模板相同）
     │   ├─ default_db 匹配
     │   └─ status = 'enabled'
     │
     ├─ 匹配成功 (HIT) ──► ③ 从 bind_sql 提取 Hint
     │                        ├─ 合并到优化器 Hint 上下文
     │                        ├─ Hint 优先级 > 优化器默认行为
     │                        └─ 按 Hint 指定的策略生成计划
     │
     └─ 未匹配 (MISS) ──► ④ 优化器自主选择计划（普通流程）
```

**Binding 匹配的关键特征**：

| 特征 | 说明 |
|------|------|
| 大小写敏感 | `SELECT` vs `select` 不会影响匹配（SQL 被归一化） |
| 空格/换行不敏感 | 格式化差异不影响匹配 |
| 常量参数化 | `status = 1` 和 `status = 2` 命中同一 Binding |
| 全局/会话 | `GLOBAL BINDING` 对所有会话生效；目前只有 GLOBAL 级别 |

---

### 7. SPM Evolve 机制（自动演进）

TiDB 支持 Binding 的自动演进（Evolve），允许优化器在"锁定计划"的基础上发现更好的计划：

```sql
-- 启用自动演进
SET GLOBAL tidb_enable_plan_replayer = ON;
SET GLOBAL tidb_evolve_task_check_interval = '30m';

-- 查看 evolve 任务列表
SELECT * FROM mysql.bind_info WHERE source = 'evolve';

-- 接受 evolve 生成的新 Binding
ADMIN EVOLVE ACCEPT TASK 'task_id_xxx';

-- 拒绝 evolve 建议
ADMIN EVOLVE REJECT TASK 'task_id_xxx';
```

**Evolve 工作流程**：

```
① 后台任务定期触发
       │
       ▼
② 对每个 Binding，尝试"无 Hint"重新优化
   → 如果发现 cost 更低的计划
       │
       ▼
③ 在不影响生产的前提下，以 1% 流量验证新计划
   → 统计新计划的 p99 延迟、资源消耗
       │
       ├─ 新计划更优 → 生成 evolve 任务，DBA 审核接受
       │
       └─ 新计划更差 → 丢弃（不通知）
```

::: warning Evolve 注意事项

- Evolve 默认关闭，需要手动开启 `tidb_enable_plan_replayer`
- Evolve 是异步后台任务，不会影响在线查询
- 新计划验证只有 1% 流量，对生产影响极小
- DBA 应定期查看 `mysql.bind_info` 中 `source = 'evolve'` 的记录
- **Binding 不跨版本保证有效**：TiDB 升级后，某些 Hint 可能语义变化或不再支持，需重新验证

:::

---

### 8. Binding vs Hint 对比

| 维度 | SQL Hint（手动） | SQL Binding（SPM） |
|------|-----------------|-------------------|
| 生效方式 | 需要修改 SQL 文本 | **无需修改 SQL**，自动匹配注入 |
| 应用代码侵入 | **需要改代码**（加 Hint 注释） | **零侵入**，DBA 在数据库层操作 |
| 适用范围 | 单条 SQL（Hint 写在哪条 SQL 就生效） | 所有匹配该 SQL 模板的查询 |
| 生效粒度 | `/*+ HINT */` 在 SQL 文本中 | 数据库全局匹配 |
| 版本升级 | 一般无影响（Hint 语法向后兼容） | **需要重新验证**（Binding 不保证跨版本） |
| 紧急止血 | 需要发布代码（分钟级） | **秒级生效**（CREATE BINDING 立即生效） |
| 回滚方式 | 重新发布（去掉 Hint） | `DROP GLOBAL BINDING` |
| 自动演进 | 不支持 | **支持 Evolve 自动发现更优计划** |
| 管理成本 | 散落在代码各处，难以统一管理 | **集中在 bind_info 表，一目了然** |

---

### 9. 清理 Binding

```sql
-- 删除指定 Binding
DROP GLOBAL BINDING FOR
  SELECT * FROM t_spm_test WHERE status = 1 AND city = 'Beijing' ORDER BY created_at DESC LIMIT 20;

-- 也可通过 sql_digest 删除
-- DROP GLOBAL BINDING FOR SQL DIGEST '42a1c8aae6f133e9a1b2c3d4e5f6a7b8';

-- 确认已删除
SHOW GLOBAL BINDINGS;
```

---

### 10. 生产实践建议

| 场景 | 建议 |
|------|------|
| 大促前准备 | 提前为关键 SQL 创建 Binding，锁定最优计划 |
| 版本升级后 | 验证所有 Binding 是否仍然有效（`status = 'enabled'`） |
| 紧急故障 | `CREATE GLOBAL BINDING` 秒级止血，事后分析根因 |
| 日常运维 | 定期检查 Evolve 建议，逐步优化 Binding |
| 长期管理 | 为 Binding 添加注释（通过变更管理系统记录创建原因） |
