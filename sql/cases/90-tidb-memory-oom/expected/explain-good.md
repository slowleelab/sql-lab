# EXPLAIN 参考结果 - good.sql（OOM 防护与优化）

## TiDB v7.5.1（30 万行，1GB 内存限额，启用临时溢出）

---

### 步骤 1: 启用临时磁盘溢出

```sql
SET GLOBAL tidb_enable_tmp_storage_on_oom = ON;
SHOW VARIABLES LIKE 'tidb_enable_tmp_storage_on_oom';
```

```
+-----------------------------------+-------+
| Variable_name                     | Value |
+-----------------------------------+-------+
| tidb_enable_tmp_storage_on_oom    | ON    |
+-----------------------------------+-------+
```

---

### 步骤 2: 合理设置内存限额

```sql
SET SESSION tidb_mem_quota_query = 1073741824; -- 1GB
```

---

### 步骤 3: EXPLAIN ANALYZE（内存控制在限制内）

```sql
EXPLAIN ANALYZE SELECT group_id, COUNT(*) AS cnt, AVG(value) AS avg_val, SUM(value) AS total
FROM t_oom_test
GROUP BY group_id
ORDER BY total DESC;
```

```
+-------------------------------------+------------+----------+-----------+----------------+----------------+-------------------------------------------------------------------------------------------------------------------------------------------------------------------------+
| id                                  | estRows    | actRows  | task      | memory         | disk           | operator info                                                                                                                                                           |
+-------------------------------------+------------+----------+-----------+----------------+----------------+-------------------------------------------------------------------------------------------------------------------------------------------------------------------------+
| Sort_5                              | 43200.00   | 50000    | root      | 1.125 MiB      | 0 Bytes        | sql_treasure.t_oom_test.total:desc                                                                                                                                      |
| └─Projection_7                      | 43200.00   | 50000    | root      | 47.5 MiB       | 0 Bytes        | sql_treasure.t_oom_test.group_id, Column#6, Column#7, Column#8                                                                                                          |
|   └─HashAgg_19                      | 43200.00   | 50000    | root      | 168.2 MiB      | 0 Bytes        | group by:sql_treasure.t_oom_test.group_id, funcs:count(1), funcs:avg(Column#10), funcs:sum(Column#9)                                                                    |
|     └─TableReader_20                | 300000.00  | 300000   | root      | 9.51 MiB       | 0 Bytes        | data:TableFullScan_21                                                                                                                                                   |
|       └─TableFullScan_21            | 300000.00  | 300000   | cop[tikv] | N/A            | N/A            | table:t_oom_test, keep order:false, stats:pseudo                                                                                                                        |
+-------------------------------------+------------+----------+-----------+----------------+----------------+-------------------------------------------------------------------------------------------------------------------------------------------------------------------------+
```

#### 关键字段说明

| 字段 | 含义 | 本次值 |
|------|------|--------|
| `estRows` | 优化器预估行数 | 43200（50000 group 的估算） |
| `actRows` | 实际返回行数 | 50000 |
| `memory` | 算子内存消耗 | HashAgg 168.2 MiB，在 1GB 限额内 |
| `disk` | 溢出到磁盘的数据量 | **0 Bytes**（未触发溢出，无需落盘） |

**关键观察**：`disk` 列全部为 `0 Bytes`，说明所有算子的内存消耗都在 `tidb_mem_quota_query = 1GB` 限额之内，**无需溢出磁盘**。与 bad.sql 场景相比，查询能正常执行完成，不会触发 OOM 错误。

---

### 步骤 4: 集群进程列表

```sql
SELECT * FROM information_schema.cluster_processlist WHERE command = 'Query';
```

```
+--------------------+------+------+-----------------+---------+---------+------+-------+--------------------------------------------------------+
| INSTANCE           | ID   | USER | HOST            | DB      | COMMAND | TIME | STATE | INFO                                                   |
+--------------------+------+------+-----------------+---------+---------+------+-------+--------------------------------------------------------+
| 127.0.0.1:4000     |    8 | root | 127.0.0.1:54321 | sql_treasure | Query   |    0 |    2  | SELECT * FROM information_schema.cluster_processlist   |
+--------------------+------+------+-----------------+---------+---------+------+-------+--------------------------------------------------------+
```

---

### 步骤 5: OOM Action 对比

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

#### OOM Action 行为对比

| 模式 | 超限时行为 | 优点 | 缺点 | 推荐场景 |
|------|-----------|------|------|---------|
| `CANCEL`（默认） | 立即中断 SQL，报错退出 | 保护 TiDB Server 不 OOM | 用户查询失败，影响业务 | 测试环境、对稳定性要求极高的场景 |
| `LOG` | 只记录日志，SQL 继续执行 | 用户无感知，不影响业务 | 可能真正耗尽内存导致 TiDB Crash | 生产环境（配合 tmp-storage） |

---

### 步骤 6: 分批聚合策略

对于超高基数 GROUP BY（如 group_id 范围极大），可分批聚合降低单次内存压力。

```sql
SELECT group_id, COUNT(*), AVG(value), SUM(value)
FROM t_oom_test
WHERE group_id BETWEEN 1 AND 10000
GROUP BY group_id;
```

```
+----------+----------+-----------+-------------+
| group_id | COUNT(*) | AVG(value)| SUM(value)  |
+----------+----------+-----------+-------------+
|        1 |        7 |  5012.14  |      35085  |
|        2 |        6 |  4876.33  |      29258  |
|        3 |        5 |  5123.80  |      25619  |
|        4 |        8 |  4437.50  |      35500  |
|        5 |        6 |  5198.67  |      31192  |
| ...      |      ... |       ... |        ...  |
+----------+----------+-----------+-------------+
```

将 50,000 个 group 拆成 5 批（每批 10,000 个），每批内存消耗从 **168 MiB 降至约 33 MiB**，可在极低内存限额下安全执行。

---

### bad.sql vs good.sql 量化对比

| 维度 | bad.sql（100MB 限额） | good.sql（1GB + 溢出 + 分批） |
|------|----------------------|------------------------------|
| `tidb_mem_quota_query` | 100 MiB | **1 GiB** |
| `tidb_enable_tmp_storage_on_oom` | ON / OFF（取决环境） | **ON** |
| HashAgg memory | 168 MiB（超限） | 168 MiB（在限额内） |
| disk 溢出 | 可能触发 `/tmp` 溢写 | 0 Bytes（未溢出） |
| 查询结果 | OOM 中断 或 溢写到磁盘 | 正常完成 |
| 执行时间 | 中断 / 磁盘溢写慢 | 正常 |
| 分批策略 | 无 | WHERE group_id BETWEEN a AND b |

---

### 内存参数配置速查表

| 参数 | 默认值 | 建议值 | 说明 |
|------|--------|--------|------|
| `tidb_mem_quota_query` | 1 GiB | 根据业务峰值调整 | 单条 SQL 的内存上限 |
| `tidb_enable_tmp_storage_on_oom` | ON | ON（生产强烈推荐） | 超限是否溢出到临时磁盘 |
| `tidb_mem_oom_action` | CANCEL | LOG（配合 tmp-storage） | 超限时中断(CANCEL)或记录(LOG) |
| `tmp-storage-path` | `/tmp/<os_user>` | 确保有 **50GB+** 可用空间 | 临时文件落盘路径 |
| `tidb_server_memory_limit` | 80% | 80% | TiDB 进程总内存上限（占系统内存百分比） |
| `tidb_server_memory_limit_gc_trigger` | 70% | 70% | 触发 Golang GC 的内存阈值 |
| `tidb_mem_quota_topn` | 0（无限制） | 可设为 64 MiB | TopN 算子内存限制 |
