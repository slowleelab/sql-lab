# EXPLAIN 参考结果 - good.sql（TiDB 高级 EXPLAIN 用法）

## TiDB v7.5.1（10 万用户 + 30 万订单）

---

### EXPLAIN ANALYZE — 实际执行统计

```sql
EXPLAIN ANALYZE SELECT id, name, city, salary FROM t_user WHERE city = 'Beijing';
```

```
+-------------------------------+----------+---------+-----------+---------------------------+------------------------------------+--------+---------+------+
| id                            | estRows  | actRows | task      | access object             | operator info                      | exec info| memory  | disk |
+-------------------------------+----------+---------+-----------+---------------------------+------------------------------------+--------+---------+------+
| IndexLookUp_7                 | 10000.00 | 9800    | root      |                           |                                    | time:8.2ms| 1.2 MB | N/A  |
| ├─IndexRangeScan_5(Build)     | 10000.00 | 9800    | cop[tikv] | table:t_user, index:idx_city | range:["Beijing","Beijing"]    | time:2.1ms| N/A     | N/A  |
| └─TableRowIDScan_6(Probe)     | 10000.00 | 9800    | cop[tikv] | table:t_user              | keep order:false                   | time:4.8ms| N/A     | N/A  |
+-------------------------------+----------+---------+-----------+---------------------------+------------------------------------+--------+---------+------+
```

`EXPLAIN ANALYZE` 比 `EXPLAIN` 多出 4 列：

| 新增列 | 说明 |
|--------|------|
| `actRows` | 实际返回的行数（`EXPLAIN` 只有 `estRows` 预估值） |
| `exec info` | 各算子实际耗时 |
| `memory` | 算子内存使用 |
| `disk` | 算子磁盘使用（溢出到磁盘时显示） |

#### 分析

- `estRows=10000` vs `actRows=9800`：预估接近实际
- `Build 阶段`耗时 2.1ms，`Probe 阶段`耗时 4.8ms：回表耗时是索引扫描的 2 倍
- 总耗时 8.2ms，内存 1.2 MB

---

### EXPLAIN FORMAT=verbose — 详细算子信息

```sql
EXPLAIN FORMAT=verbose SELECT city, COUNT(*) AS cnt FROM t_user GROUP BY city;
```

```
+------------------------------+----------+-----------+---------------+----------------------------------------------+
| id                           | estRows  | task      | access object | operator info                                |
+------------------------------+----------+-----------+---------------+----------------------------------------------+
| HashAgg_9                    | 10.00    | root      |               | group by:t_user.city, funcs:count(Column#7)->Column#5 |
| └─TableReader_10             | 100000.00| root      |               | data:TableFullScan_8                         |
|   └─TableFullScan_8          | 100000.00| cop[tikv] | table:t_user  | keep order:false                             |
+------------------------------+----------+-----------+---------------+----------------------------------------------+
```

`FORMAT=verbose` 展示更详细的 `operator info`（如具体的列引用 `Column#7`）。

---

### 覆盖索引避免回表

```sql
EXPLAIN SELECT city FROM t_user WHERE city = 'Beijing';
```

```
+-------------------------------+----------+-----------+---------------------------+----------------------------------+
| id                            | estRows  | task      | access object             | operator info                    |
+-------------------------------+----------+-----------+---------------------------+----------------------------------+
| IndexReader_6                 | 10000.00 | root      |                           | index:IndexRangeScan_5           |
| └─IndexRangeScan_5            | 10000.00 | cop[tikv] | table:t_user, index:idx_city | range:["Beijing","Beijing"]  |
+-------------------------------+----------+-----------+---------------------------+----------------------------------+
```

#### 关键差异

| 指标 | bad.sql (非覆盖索引) | good.sql (覆盖索引) |
|------|---------------------|---------------------|
| 最外层算子 | `IndexLookUp_7` | `IndexReader_6` |
| 回表 | **需要** TableRowIDScan | **不需要**回表 |
| Build/Probe | 两阶段 | 单阶段 |
| 性能 | 约 8ms | 约 3ms |

`IndexReader` 表示直接从索引返回所有结果，**没有 IndexLookUp 即没有回表**。这与 MySQL `Extra: Using index` 的语义相同。

---

## TiDB EXPLAIN 核心概念总结

| TiDB 概念 | MySQL 对应 | 说明 |
|-----------|-----------|------|
| `estRows` | `rows` | 预估行数 |
| `actRows` | 无 | EXPLAIN ANALYZE 的实际行数 |
| `task: cop[tikv]` | 无 | 下推到 TiKV 执行（类似索引条件下推但更激进） |
| `task: root` | 无 | 在 TiDB SQL 层执行 |
| `access object` | `key` + `ref` | 访问的数据对象（表/索引/分区） |
| `operator info` | `Extra` | 算子补充信息 |
| `TableFullScan` | `type: ALL` | 全表扫描 |
| `IndexRangeScan` | `type: range` | 索引范围扫描 |
| `IndexLookUp` | `Extra: Using index condition` | 需要回表 |
| `IndexReader` | `Extra: Using index` | 覆盖索引，无需回表 |
| `HashAgg` | `Extra: Using temporary` | 哈希聚合 |
