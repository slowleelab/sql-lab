# EXPLAIN 参考结果 - good.sql (ORDER BY LIMIT 走索引)

## MySQL 8.0（实测 8.0.46，20 万行数据）

```
+----+-------------+-----------+-------+---------------+------------+---------+------+------+----------+-------+
| id | select_type | table     | type  | possible_keys | key        | key_len | ref  | rows | filtered | Extra |
+----+-------------+-----------+-------+---------------+------------+---------+------+------+----------+-------+
|  1 | SIMPLE      | t_message | index | NULL          | idx_created| 5       | NULL |   10 |   100.00 | NULL  |
+----+-------------+-----------+-------+---------------+------------+---------+------+------+----------+-------+
```

## 关键改进

| 字段 | 值 | 分析 |
|------|-----|------|
| type | **`index`** | 索引扫描（有序） |
| key | `idx_created` | 使用 created_at 索引 |
| key_len | `5` | DATETIME = 5 字节 |
| rows | **`10`** | **只扫描 10 行！** |
| Extra | **`NULL`** | **filesort 消失！** |

## 为什么更好

`idx_created (created_at)` 是 B+ 树索引，天然按 created_at 有序存储：

1. **索引有序**：DESC 只需从索引末尾（最大值）反向扫描
2. **只取 N 条**：扫描索引最右端 10 个叶子节点即可，无需全表
3. **回表 10 次**：取到 10 个主键后回表读取完整行数据
4. **无 filesort**：索引本身有序，无需额外排序

### 执行流程（优化后）

```
1. 定位 idx_created 索引最右端（最大 created_at）
2. 反向扫描索引，取 10 个叶子节点（10 个主键 id）
3. 用这 10 个 id 回表读取完整行
4. 返回结果
（无全表扫描、无 filesort）
```

## 量化对比

| 指标 | bad.sql (无索引) | good.sql (有索引) | 提升 |
|------|------------------|-------------------|------|
| type | ALL | index | 全表 -> 索引 |
| rows | ~198,624 | **10** | **减少 99.995%** |
| Extra | Using filesort | NULL | **消除排序** |
| 回表次数 | 0（直接读全表） | 10 | 仅必要回表 |
| 耗时 | ~150 ms | ~1 ms | **约 150 倍** |

## 进阶: 覆盖索引进一步优化

若查询只需索引列，可避免回表：

```sql
-- 只查 created_at（覆盖索引，无需回表）
SELECT created_at FROM t_message ORDER BY created_at DESC LIMIT 10;
-- Extra: Using index（覆盖索引，最快）
```

若需多列，可建联合索引：

```sql
-- 常见模式: 按用户取最新消息
ALTER TABLE t_message ADD KEY idx_user_created (user_id, created_at);
SELECT * FROM t_message WHERE user_id = 12345 ORDER BY created_at DESC LIMIT 10;
-- 用 idx_user_created 定位到该用户，再按 created_at 倒序取 10 条
```

::: tip ORDER BY + LIMIT 索引设计原则
1. **排序字段建索引**：ORDER BY 的列建索引，利用 B+ 树有序性
2. **方向一致**：索引默认 ASC，ORDER BY DESC 也能反向扫描（无需专门建 DESC 索引，8.0 支持降序索引）
3. **配合 WHERE**：若 WHERE + ORDER BY 同时存在，建 (过滤列, 排序列) 联合索引
4. **LIMIT 越小收益越大**：LIMIT 10 时索引只扫 10 行，全表则扫全部
:::
