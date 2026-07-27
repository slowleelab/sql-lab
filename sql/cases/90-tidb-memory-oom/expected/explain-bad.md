# EXPLAIN 参考结果 - bad.sql（低内存限额触发 OOM）

## TiDB v7.5.1（30 万行，50000 个 group）

---

### 步骤 1: 当前内存相关参数

```sql
SHOW VARIABLES LIKE '%mem%';
```

```
+--------------------------------------+-----------+
| Variable_name                        | Value     |
+--------------------------------------+-----------+
| tidb_mem_oom_action                  | CANCEL    |
| tidb_mem_quota_analyze               | 0         |
| tidb_mem_quota_apply_cache           | 33554432  |
| tidb_mem_quota_binding_cache         | 67108864  |
| tidb_mem_quota_query                 | 1073741824|
| tidb_mem_quota_topn                  | 0         |
| tidb_enable_tmp_storage_on_oom       | ON        |
| tidb_server_memory_limit             | 80%       |
| tidb_server_memory_limit_gc_trigger  | 70%       |
| tidb_server_memory_limit_sess_min_size| 134217728 |
+--------------------------------------+-----------+
```

---

### 步骤 2: 设置低内存限额（100MB）

```sql
SET SESSION tidb_mem_quota_query = 104857600; -- 100MB
```

---

### 步骤 3: EXPLAIN ANALYZE（内存超限）

```sql
EXPLAIN ANALYZE SELECT group_id, COUNT(*) AS cnt, AVG(value) AS avg_val, SUM(value) AS total
FROM t_oom_test
GROUP BY group_id
ORDER BY total DESC;
```

```
+-------------------------------------+------------+----------+-----------+----------------+-------------------------------------------------------------------------------------------------------------------------------------------------------------------------+
| id                                  | estRows    | actRows  | task      | memory         | operator info                                                                                                                                                           |
+-------------------------------------+------------+----------+-----------+----------------+-------------------------------------------------------------------------------------------------------------------------------------------------------------------------+
| Sort_5                              | 43200.00   | 50000    | root      | 1.125 MiB      | sql_treasure.t_oom_test.total:desc                                                                                                                                      |
| └─Projection_7                      | 43200.00   | 50000    | root      | 47.5 MiB       | sql_treasure.t_oom_test.group_id, Column#6, Column#7, Column#8                                                                                                          |
|   └─HashAgg_19                      | 43200.00   | 50000    | root      | 168.2 MiB      | group by:sql_treasure.t_oom_test.group_id, funcs:count(1), funcs:avg(Column#10), funcs:sum(Column#9)                                                                    |
|     └─TableReader_20                | 300000.00  | 300000   | root      | 9.51 MiB       | data:TableFullScan_21                                                                                                                                                   |
|       └─TableFullScan_21            | 300000.00  | 300000   | cop[tikv] | N/A            | table:t_oom_test, keep order:false, stats:pseudo                                                                                                                        |
+-------------------------------------+------------+----------+-----------+----------------+-------------------------------------------------------------------------------------------------------------------------------------------------------------------------+
```

#### 内存分析

| 算子 | 类型 | memory 消耗 | 说明 |
|------|------|------------|------|
| `HashAgg_19` | 哈希聚合 | **168.2 MiB** | 50,000 个 group 在内存中构建哈希表，内存消耗最大 |
| `Projection_7` | 投影 | 47.5 MiB | 结果集投影暂存 |
| `Sort_5` | 排序 | 1.125 MiB | ORDER BY total DESC 需排序缓冲区 |
| `TableFullScan_21` | 全表扫描 | 在 TiKV 侧 | 30 万行数据扫描 |

**关键观察**：`HashAgg_19` 的 `memory` 为 **168.2 MiB**，已超过 100MB 限额。如果 `tidb_enable_tmp_storage_on_oom = OFF`，此查询将直接报错：

```
ERROR 1105 (HY000): Out Of Memory Quota!
```

如果 `tidb_enable_tmp_storage_on_oom = ON`（默认），HashAgg 会将超限数据溢出到临时磁盘目录，查询不会中断。对应的 `operator info` 中会显示 `spill to disk` 字样。

---

### 步骤 4: OOM Action 模式

```sql
SHOW VARIABLES LIKE 'tidb_mem_oom_action';
```

```
+--------------------+--------+
| Variable_name      | Value  |
+--------------------+--------+
| tidb_mem_oom_action | CANCEL |
+--------------------+--------+
```

| 值 | 行为 | 适用场景 |
|----|------|---------|
| `CANCEL` | 超限时**立即中断**当前 SQL，报错退出 | 测试环境、保护数据库稳定性 |
| `LOG` | 超限时只**记录日志**，不中断 SQL | 生产环境、不希望用户查询报错 |

---

### HashAgg 内存超限的典型信号

在 EXPLAIN ANALYZE 结果中查找以下危险信号：

| 信号 | 位置 | 严重程度 |
|------|------|:--------:|
| `memory` > `tidb_mem_quota_query` | HashAgg / HashJoin 算子 | 严重 |
| `Out Of Memory Quota!` 错误 | 客户端返回 | 严重 |
| `disk` 列有值 | EXPLAIN ANALYZE | 警告（溢出发生） |
| `spill to disk` 字样 | operator info | 警告 |
