# EXPLAIN 参考结果 - good.sql (只查必要列)

## MySQL 8.0（10 万行数据）

```
+----+-------------+-----------+------------+-------+----------------------+----------------------+---------+------+--------+----------+-----------------------+
| id | select_type | table     | partitions | type  | possible_keys        | key                  | key_len | ref  | rows   | filtered | Extra                 |
+----+-------------+-----------+------------+-------+----------------------+----------------------+---------+------+--------+----------+-----------------------+
|  1 | SIMPLE      | t_article | NULL       | ref   | idx_category_created | idx_category_created | 82      | const|  20000 |   100.00 | Backward index scan   |
+----+-------------+-----------+------------+-------+----------------------+----------------------+---------+------+--------+----------+-----------------------+
```

## 关键改进

| 字段 | 值 | 分析 |
|------|-----|------|
| type | `ref` | 同样走索引定位 category='技术' |
| key | `idx_category_created` | 用了 (category, created_at) 索引 |
| rows | ~20,000 | 预估扫描行数相同 |
| Extra | `Backward index scan` | 逆向扫描 |

## 为什么快

执行计划与 bad 方案看似相同（都需要回表），但**回表读取的数据量天差地别**：

1. bad 方案回表读 `SELECT *`：包含 2KB 的 TEXT content -> 需追踪溢出页链
2. good 方案回表读 6 个小字段：不含 TEXT -> 聚簇索引行内数据即可满足，**无需读溢出页**
3. 网络传输量从 ~42 KB 降至 ~6 KB，减少约 85%
4. 内存占用大幅降低，Buffer Pool 命中率提升

### 进一步优化：覆盖索引

如果将 `views` 也加入索引，可实现完全的覆盖索引（Using index），连回表都省掉：

```sql
-- setup-good.sql 可选的进一步优化：
ALTER TABLE t_article ADD KEY idx_category_created_views (category, created_at, views);
```

此时 Extra 会显示 `Using index`，完全不需要回表聚簇索引。

## 量化对比

| 指标 | bad (SELECT *) | good (只查必要列) | 提升 |
|------|----------------|-------------------|------|
| 耗时 | ~120 ms | ~35 ms | **约 3.4 倍** |
| 每行数据量 | ~2.1 KB | ~0.3 KB | **减少 85%** |
| 20 行传输量 | ~42 KB | ~6 KB | **减少 85%** |
| 溢出页 I/O | 需要 | 不需要 | **消除** |

## 5.7 vs 8.0 差异

- 执行计划结构一致，优化方案在两个版本上都有效
- 8.0 Extra 显示 `Backward index scan`，5.7 显示 `Using filesort`
- TEXT 存储机制相同（DYNAMIC 行格式），优化原理一致

## 避坑指南

1. **永远不要在业务查询中使用 SELECT \***：尤其是含 TEXT/BLOB 字段的表，明确列出所需列
2. **TEXT/BLOB 字段单独拆表**：将大字段拆到扩展表（如 t_article_content），主表只存元数据
3. **列表页和详情页分离**：列表页不查 content，详情页按主键单独查 content
4. **注意 VARCHAR 也可能溢出**：VARCHAR 超过行大小限制时同样会溢出到 off-page
5. **监控 off-page I/O**：通过 `SHOW ENGINE INNODB STATUS` 关注 BLOB page 的读取情况
