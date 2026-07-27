# EXPLAIN 参考结果 - bad.sql (单列索引 + filesort)

## MySQL 8.0（t_document_soft，10 万行，仅有 idx_author 单列索引）

```
+----+-------------+------------------+------------+------+---------------+------------+---------+-------+------+----------+----------------------------------------------+
| id | select_type | table            | partitions | type | possible_keys | key        | key_len | ref   | rows | filtered | Extra                                        |
+----+-------------+------------------+------------+------+---------------+------------+---------+-------+------+----------+----------------------------------------------+
|  1 | SIMPLE      | t_document_soft  | NULL       | ref  | idx_author    | idx_author | 8       | const |    4 |   10.00 | Using where; Using filesort                  |
+----+-------------+------------------+------------+------+---------------+------------+---------+-------+------+----------+----------------------------------------------+
```

## 关键问题

| 字段 | 值 | 分析 |
|------|-----|------|
| type | `ref` | 走了 idx_author 等值查找 author_id=12345 |
| possible_keys | `idx_author` | 只有单列索引可用 |
| key | `idx_author` | 用了 author_id 单列索引 |
| rows | ~4 | 预估命中约 4 行（author_id=12345 的行） |
| filtered | 10.00 | 回表后还需用 `deleted_at IS NULL` 过滤，仅约 10% 命中 |
| Extra | **`Using where; Using filesort`** | 回表过滤 + **filesort 排序** |

## 为什么慢

看似走了索引（type=ref），但有两个严重问题：

### 1. deleted_at IS NULL 无法在索引层过滤

`idx_author` 只包含 `author_id`，不包含 `deleted_at`。优化器定位到 `author_id=12345` 的行后，必须**回表**读取完整行，再在 server 层用 `deleted_at IS NULL` 过滤。已软删除的行做了**无效回表**。

### 2. ORDER BY created_at 触发 filesort

`idx_author` 不包含 `created_at`，索引中数据不按 created_at 排序。优化器无法利用索引的有序性，必须把过滤后的行全部取出，再用 **filesort**（额外排序）按 created_at DESC 排序。

```
执行流程:
  1. idx_author 定位 author_id=12345 的所有行（预估约 4 行）
  2. 逐行回表读完整数据
  3. server 层用 deleted_at IS NULL 过滤（丢掉已删除行，filtered 仅 10%）
  4. 对剩余行做 filesort（按 created_at DESC 排序）
  5. 取 LIMIT 20 返回

问题:
  - 步骤2: 已删除行无效回表（I/O 浪费）
  - 步骤4: filesort 占用 sort_buffer，数据多时可能落临时表磁盘
```

### 数据量放大后的代价

本案例 author_id=12345 只有约 4 行（filtered 10% 意味着大部分是已删除行），filesort 开销小。但生产环境中：
- 某 author 可能有多达数千上万行文档
- filtered 仅 10%，意味着约 90% 的回表是浪费的（读出来才发现已软删除）
- filesort 在结果集大时可能使用磁盘临时表，代价剧增

```
放大场景（某作者有 1 万行，filtered 约 10%）:
  - 回表 1 万次（其中约 9000 次因 deleted_at 非空而浪费）
  - filesort 约 1000 行（按 created_at DESC 排序）
  - 数据量大时 filesort 落磁盘 -> 严重慢查询
```

实际耗时：约 **6 ms**（实测 MySQL 8.0.46，author_id=12345 仅约 4 行）。
某作者文档量大时（如千行级），耗时可达 **50-200 ms**。

## MySQL 5.7 差异

5.7 行为一致，同样出现 `Using filesort`。软删除索引设计问题与版本无关。
