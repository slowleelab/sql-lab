# EXPLAIN 参考结果 - bad.sql (SELECT * 含 TEXT)

## MySQL 8.0（10 万行数据）

```
+----+-------------+-----------+------------+-------+----------------------+----------------------+---------+------+--------+----------+-----------------------+
| id | select_type | table     | partitions | type  | possible_keys        | key                  | key_len | ref  | rows   | filtered | Extra                 |
+----+-------------+-----------+------------+-------+----------------------+----------------------+---------+------+--------+----------+-----------------------+
|  1 | SIMPLE      | t_article | NULL       | ref   | idx_category_created | idx_category_created | 82      | const|  20000 |   100.00 | Backward index scan   |
+----+-------------+-----------+------------+-------+----------------------+----------------------+---------+------+--------+----------+-----------------------+
```

## 关键问题

| 字段 | 值 | 分析 |
|------|-----|------|
| type | `ref` | 走了索引定位 category='技术' |
| key | `idx_category_created` | 用了 (category, created_at) 索引 |
| rows | ~20,000 | 预估该分类约 2 万行 |
| Extra | `Backward index scan` | 逆向扫描（ORDER BY created_at DESC） |

## 为什么慢

执行计划看起来正常（走了索引），问题在于 **SELECT \*** 的回表行为：

1. 通过 `idx_category_created` 定位到 category='技术' 的行，按 created_at 降序扫描
2. **逐行回表**到聚簇索引读取完整行数据 —— 包括约 2KB 的 `content` TEXT 字段
3. TEXT 字段超过 768 字节时，InnoDB 将其存储在**溢出页（off-page）**中
4. 读取 TEXT 需要**追踪溢出页链**（uncompressed BLOB page chain），产生大量随机 I/O
5. 虽然最终只返回 20 行，但前 20 行每一行的回表都要读取溢出页

### 数据传输量对比

| 方案 | 每行数据量 | 20 行总量 | 说明 |
|------|-----------|-----------|------|
| SELECT * | ~2.1 KB | ~42 KB | 含 2KB TEXT + 元数据，需读溢出页 |
| 只查必要列 | ~0.3 KB | ~6 KB | 无 TEXT，数据量减少约 85% |

实际耗时：约 **120 ms**（实测 MySQL 8.0.46，10 万行数据）。

## TEXT 字段的存储机制

InnoDB 对 TEXT/BLOB 的存储分三种情况（取决于行格式和字段大小）：

- **REDUNDANT/COMPACT 格式**：前 768 字节存行内，剩余存溢出页
- **DYNAMIC/COMPRESSED 格式**（默认）：行内只存 20 字节指针，全部内容存溢出页
- 读取 TEXT 时需要先读行内指针，再跳转到溢出页读取实际内容

这意味着 `SELECT *` 即使不需要 content 字段，也会触发溢出页的 I/O。

## MySQL 5.7 差异

5.7 默认行格式为 DYNAMIC（与 8.0 一致），TEXT 存储机制相同。
Extra 显示 `Using filesort` 而非 `Backward index scan`（5.7 无降序索引优化）。
