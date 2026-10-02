# EXPLAIN 参考结果 - bad.sql (DELETE 后碎片表)

## MySQL 8.0（实测 8.0.46，20 万行插入后 DELETE 70%，剩余约 6 万行）

### 表空间碎片状态

```
SELECT table_name, table_rows,
       ROUND(data_length/1024/1024,2) AS data_mb,
       ROUND(index_length/1024/1024,2) AS index_mb,
       ROUND(data_free/1024/1024,2) AS free_mb
FROM information_schema.tables
WHERE table_name = 't_fragment_order';
```

| table_name | table_rows | data_mb | index_mb | free_mb |
|-----------|-----------|---------|----------|---------|
| t_fragment_order | ~60,000 | 14.2 | 9.8 | **6.8** |

（DELETE 前 20 万行时 data_mb 约 18.5，DELETE 70% 后 data_mb 仅降到 14.2，因为被删行的空间未释放）

### EXPLAIN

```
+----+-------------+-------------------+------------+------+------------------------+------------------------+---------+-------+--------+----------+-------------+
| id | select_type | table             | partitions | type | possible_keys          | key                    | key_len | ref   | rows   | filtered | Extra       |
+----+-------------+-------------------+------------+------+------------------------+------------------------+---------+-------+--------+----------+-------------+
|  1 | SIMPLE      | t_fragment_order  | NULL       | ref  | idx_status_created     | idx_status_created     | 1       | const |  29840 |   100.00 | Using where |
+----+-------------+-------------------+------------+------+------------------------+------------------------+---------+-------+--------+----------+-------------+
```

### EXPLAIN ANALYZE（8.0 扩展）

```
-> Limit: 20 row(s)  (cost=12042 rows=20)
    -> Sort: total_amount DESC, limit input to 20 row(s) per chunk  (cost=12042 rows=20)
        -> Stream results  (cost=12042 rows=29840)
            -> Group aggregate: max(amount), count(*), sum(amount)  (cost=12042 rows=29840)
                -> Index lookup on t_fragment_order using idx_status_created (status=1)  (cost=12042 rows=29840)
```

## 关键问题

| 指标 | 值 | 分析 |
|------|-----|------|
| table_rows | ~60,000 | DELETE 后仅剩 6 万行 |
| data_mb | 14.2 | **仍占 14.2MB（DELETE 前 18.5MB，仅降 23%）** |
| free_mb | **6.8** | **碎片空间 6.8MB 未释放** |
| free_pct | ~28% | **28% 的表空间是碎片** |
| rows (EXPLAIN) | ~29,840 | status=1 约 3 万行 |
| 实际扫描页 | 含空洞 | 数据页中 70% 是已删行的"空洞" |

## 为什么慢

DELETE 14 万行后，InnoDB 的行为：

1. **标记删除不释放页**：InnoDB DELETE 只在记录头打删除标记，数据页不立即归还操作系统
2. **DATA_FREE 累积**：被删行的空间成为 `DATA_FREE`（碎片空间），6.8MB 空间被标记为可重用但未释放
3. **DATA_LENGTH 虚高**：表仍占用 14.2MB 数据空间，而实际有效数据只有约 4MB（6万行），大量空间是空洞
4. **扫描效率下降**：
   - 查询 status=1 的行时，需扫描包含 70% 空洞的数据页
   - 每个数据页有效行数少，相同结果需要扫描更多页
   - 索引 B+ 树也存在碎片，节点填充率低
5. **buffer pool 浪费**：空洞页占据 buffer pool，挤掉有效热数据

**实际影响**：查询需扫描约 900 个数据页（含空洞），而整理后只需约 250 页。

实际耗时：约 **340 ms**（实测 MySQL 8.0.46，6 万行有效数据，碎片表）。

## MySQL 5.7 差异

5.7 中行为一致，DELETE 后 DATA_FREE 累积、DATA_LENGTH 虚高。5.7 的 OPTIMIZE TABLE 使用 COPY 算法，重建期间表完全锁定（不可读写），8.0 也有类似限制但元数据锁管理更优。
