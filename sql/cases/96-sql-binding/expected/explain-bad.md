# EXPLAIN 参考结果 - bad.sql（无 Binding，优化器可能选错计划）

## TiDB v7.5+（30 万行，status=1 占 90%）

---

### 1. 数据分布确认

```sql
SELECT status, COUNT(*) AS cnt, CONCAT(ROUND(COUNT(*) / 300000 * 100, 2), '%') AS pct
FROM t_spm_test GROUP BY status ORDER BY status;
```

```
+--------+--------+--------+
| status | cnt    | pct    |
+--------+--------+--------+
|      0 |  15000 | 5.00%  |
|      1 | 270000 | 90.00% |
|      2 |  15000 | 5.00%  |
+--------+--------+--------+
```

关键发现：**status=1 覆盖 90% 的数据（270,000/300,000）**。这是典型的低选择性列——单独用 `idx_status` 过滤 status=1 需要回表 27 万行，优化器会认为代价极高。

---

### 2. EXPLAIN 分析（优化器选择全表扫描）

```sql
EXPLAIN SELECT * FROM t_spm_test
WHERE status = 1 AND city = 'Beijing'
ORDER BY created_at DESC
LIMIT 20;
```

**可能的结果 A（全表扫描 + Sort）——优化器认为回表代价过高：**

```
+------------------------------+----------+-----------+-------------------------------+----------------------------------------------+
| id                           | estRows  | task      | access object                 | operator info                                |
+------------------------------+----------+-----------+-------------------------------+----------------------------------------------+
| TopN_8                       | 20.00    | root      |                               | t_spm_test.created_at:desc, offset:0, count:20 |
| └─TableReader_14             | 17100.00 | root      |                               | data:Selection_13                            |
|   └─Selection_13             | 17100.00 | cop[tikv] |                               | eq(t_spm_test.city, "Beijing")                |
|     └─TableFullScan_12       | 270000.00| cop[tikv] | table:t_spm_test              | keep order:false                             |
+------------------------------+----------+-----------+-------------------------------+----------------------------------------------+
```

| 字段 | 值 | 分析 |
|------|-----|------|
| TableFullScan | `estRows: 270000` | **全表扫描**——优化器认为 status=1 回表 27 万行代价过高 |
| Selection | `eq(city, "Beijing")` | city 过滤在扫描后执行（无法走索引） |
| TopN | `offset:0, count:20` | 全表扫描结果排序后取前 20 |
| access object | `table:t_spm_test` | 未使用任何索引 |

**可能的结果 B（IndexLookUp 走 idx_status）——取决于统计信息精度：**

```
+------------------------------+----------+-----------+------------------------------------+----------------------------------------------+
| id                           | estRows  | task      | access object                      | operator info                                |
+------------------------------+----------+-----------+------------------------------------+----------------------------------------------+
| TopN_8                       | 20.00    | root      |                                    | t_spm_test.created_at:desc, offset:0, count:20 |
| └─IndexLookUp_7              | 2700.00  | root      |                                    |                                              |
|   ├─IndexRangeScan_5(Build)  | 270000.00| cop[tikv] | table:t_spm_test, index:idx_status  | range:[1,1], keep order:false               |
|   └─Selection_6(Probe)       | 2700.00  | cop[tikv] |                                    | eq(t_spm_test.city, "Beijing")               |
|     └─TableRowIDScan_7       | 270000.00| cop[tikv] | table:t_spm_test                   | keep order:false                             |
+------------------------------+----------+-----------+------------------------------------+----------------------------------------------+
```

---

### 3. 为什么优化器会选错计划

status 列的选择性极低（90% 的行都是 status=1），优化器做成本估算时：

```
走 idx_status:
  索引扫描: 270,000 行（几乎整个索引）
  回表读取: 270,000 次随机 I/O（从索引 row_id 去主表取值）
  city 过滤: 内存中过滤，约 270,000 * (1/10) = 27,000 行
  排序:     27,000 行 TopN
  总成本: 极高（回表 270,000 次）

走全表扫描:
  全表扫描: 300,000 行顺序读（预读友好）
  city 过滤: 内存中过滤，约 300,000 * (1/10) = 30,000 行
  排序:     30,000 行 TopN
  总成本: 中（顺序 I/O 远快于随机 I/O）
```

**优化器的判断在"纯成本模型"下是合理的**：27 万次随机回表 vs 30 万行顺序扫描，后者确实更便宜。但它忽略了两个关键因素：

1. **LIMIT 20 的影响被低估**：如果 city='Beijing' 的行在索引中按 `created_at` 排序后能快速找到 20 行，实际回表量远小于 27 万
2. **实际数据分布**：city='Beijing' 的行可能在表中聚集，使得扫描更快找到 20 行

这就是 SPM Binding 需要介入的场景——**人工经验可以纠正优化器的纯成本模型偏差**。

---

### 4. SHOW GLOBAL BINDINGS（确认无绑定）

```sql
SHOW GLOBAL BINDINGS;
```

```
Empty set (0.00 sec)
```

当前没有任何 Binding，优化器完全自主选择执行计划。

---

### 5. SHOW INDEX

```sql
SHOW INDEX FROM t_spm_test;
```

```
+------------+------------+-------------+--------------+-------------+-----------+...
| Table      | Non_unique | Key_name    | Seq_in_index | Column_name | Collation |...
+------------+------------+-------------+--------------+-------------+-----------+...
| t_spm_test |          0 | PRIMARY     |            1 | id          | A         |...
| t_spm_test |          1 | idx_status  |            1 | status      | A         |...
| t_spm_test |          1 | idx_city    |            1 | city        | A         |...
| t_spm_test |          1 | idx_created |            1 | created_at  | A         |...
+------------+------------+-------------+--------------+-------------+-----------+...
```

表中存在三个单列索引：`idx_status`、`idx_city`、`idx_created`，但没有复合索引。优化器只能选择其中一个索引，然后回表过滤其他条件。

---

### 6. 真正的风险：执行计划突变

在生产环境中，以下场景可能触发计划切换：

| 触发条件 | 说明 |
|---------|------|
| 统计信息更新 | ANALYZE 后直方图边界变化，成本估算漂移 |
| TiDB 版本升级 | 优化器成本模型参数调整 |
| 数据量变化 | status 分布变化（如大批量状态更新后） |
| 集群拓扑变化 | TiKV 节点增减影响网络延迟估算 |

这意味着：**一个今天跑得很好的 SQL，明天可能因为自动 ANALYZE 而突然变慢**。SPM Binding 就是为此设计的"计划锁定"机制。
