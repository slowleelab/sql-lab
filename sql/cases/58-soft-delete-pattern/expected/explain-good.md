# EXPLAIN 参考结果 - good.sql (联合索引 idx_author_deleted_created)

## MySQL 8.0（执行 setup-good.sql 后，新增联合索引）

```
+----+-------------+------------------+------------+------+---------------------------------------------+-------------------------------+---------+-------------+------+----------+--------------------------------+
| id | select_type | table            | partitions | type | possible_keys                               | key                           | key_len | ref         | rows | filtered | Extra                          |
+----+-------------+------------------+------------+------+---------------------------------------------+-------------------------------+---------+-------------+------+----------+--------------------------------+
|  1 | SIMPLE      | t_document_soft  | NULL       | ref  | idx_author,idx_author_deleted_created       | idx_author_deleted_created    | 14      | const,const |    3 |   100.00 | Using where; Backward index scan |
+----+-------------+------------------+------------+------+---------------------------------------------+-------------------------------+---------+-------------+------+----------+--------------------------------+
```

## 关键改进

| 字段 | 值 | 分析 |
|------|-----|------|
| type | `ref` | 索引等值查找（author_id + deleted_at 均为等值/IS NULL 匹配） |
| possible_keys | `idx_author, idx_author_deleted_created` | 优化器识别到两个候选索引 |
| key | `idx_author_deleted_created` | **选择联合索引**（更优） |
| key_len | 14 | 用到 author_id(8) + deleted_at(NULL 标记 5+1) 两列 |
| ref | `const,const` | 两列均为常量等值匹配（12345 / NULL） |
| rows | ~3 | 预估仅扫描约 3 行（精准定位未删除文档） |
| filtered | 100.00 | 索引层已过滤完毕，无需 server 层再过滤 |
| Extra | `Using where; Backward index scan` | deleted_at IS NULL 终检 + 逆向扫描索引（ORDER BY DESC），**无 filesort** |

## 为什么快

联合索引 `(author_id, deleted_at, created_at)` 完美覆盖了查询的三个条件：

### 索引列顺序设计原理

```
索引: (author_id, deleted_at, created_at)
       ^^^^^^^^^  ^^^^^^^^^^  ^^^^^^^^^^
       等值定位    IS NULL过滤   排序依据
```

1. **author_id 等值定位**（最左列）：用 `author_id = 12345` 精准定位，索引 B+ 树直接跳到该区间
2. **deleted_at IS NULL 过滤**（第二列）：在 author_id 区间内，deleted_at 有序排列，NULL 值集中在区间头部/尾部，可直接范围扫描过滤，**无需回表判断**
3. **created_at 有序**（第三列）：在 (author_id, deleted_at) 确定的子区间内，created_at 已按索引顺序排列，**ORDER BY created_at DESC 直接逆向扫描索引即可**，无需 filesort
4. **LIMIT 20 提前终止**：索引有序 + LIMIT，扫够 20 行即停，不必处理全部匹配行

### 对比 bad 方案的执行流程

```
bad (idx_author):
  1. 定位 author_id=12345 的所有行（含已删除）
  2. 逐行回表读完整数据
  3. server 层过滤 deleted_at IS NULL（浪费已删除行的回表）
  4. filesort 按 created_at DESC 排序
  5. LIMIT 20

good (idx_author_deleted_created):
  1. 索引直接定位 (author_id=12345, deleted_at=NULL) 子区间
  2. 该子区间内 created_at 已有序，逆向扫描
  3. LIMIT 20 扫够即停
  4. 仅对最终 20 行回表读完整数据（SELECT *）
  -> 无无效回表、无 filesort
```

### 为什么 deleted_at 放在 created_at 前面

软删除场景下，几乎所有查询都带 `deleted_at IS NULL`。把它放在 `created_at` 前面：
- 等值/IS NULL 条件放在中间列，让后续列（created_at）仍能利用索引有序性
- 若顺序是 (author_id, created_at, deleted_at)，则 created_at 在中间，deleted_at IS NULL 在末尾，ORDER BY created_at 仍会 filesort（范围列后无法保序）

**核心原则**：等值列在前，范围/排序列在后。`IS NULL` 属于等值类匹配，可让后续列保持有序。

## 量化对比

| 指标 | bad (idx_author) | good (联合索引) | 提升 |
|------|------------------|-----------------|------|
| type | ref | ref | 均走索引定位 |
| key | idx_author | idx_author_deleted_created | 选择更优联合索引 |
| key_len | 8（仅 author_id） | 14（author_id+deleted_at） | 多用一列过滤 |
| rows | ~4 | ~3 | **减少 25%** |
| filtered | 10.00% | 100% | 索引层已过滤完毕 |
| Extra | Using where; Using filesort | Using where; Backward index scan | **消除 filesort** |
| filesort | 有 | 无 | 消除 |
| 耗时 | ~6 ms | ~1 ms | **约 6 倍** |

> 本案例 author_id=12345 仅约 4 行，filesort 开销小，单次耗时差距不明显。
> 作者文档量大时差距更显著：千行级数据 bad 方案需 filesort 千行，good 方案利用索引有序性 + LIMIT 仅扫描需要的行数。

## 5.7 vs 8.0 差异

- 执行计划结构一致，联合索引方案在两个版本上都有效
- 8.0 Extra 显示 `Backward index scan`（逆向索引扫描优化 ORDER BY DESC），5.7 显示 `Using filesort`（5.7 无降序索引优化，需额外排序）
- 8.0 降序索引（`created_at DESC` 显式声明）可进一步优化，但本案例 ORDER BY ... DESC 8.0 默认走 Backward index scan 已足够

## 避坑指南

1. **软删除字段要纳入索引**：所有查询都带 `deleted_at IS NULL`，它应作为联合索引的等值列，而非被忽略
2. **等值列在前，排序列在后**：`(author_id, deleted_at, created_at)` 顺序让排序走索引，避免 filesort
3. **不要只建单列索引**：仅 `idx_author` 会导致 deleted_at 过滤回表 + created_at filesort
4. **考虑部分索引优化**：若已删除数据占比高，可考虑把已删除数据归档到历史表，减少主表体积
5. **deleted_at 用 NULL 而非 0/1**：NULL 语义清晰（未删除=未设置删除时间），且 `IS NULL` 可走索引；若用 `is_deleted TINYINT`，0/1 选择性极低，单独建索引意义不大
6. **定期清理软删除数据**：长期累积的软删除行会膨胀表和索引，应定期归档或物理清理
7. **注意 SELECT \* 回表**：若只需 title/author_id 等少数列，可建覆盖索引避免回表；本案例 SELECT \* 需回表读 content(TEXT)
8. **唯一约束要考虑软删除**：如要求同一 author 下 title 唯一，唯一索引应包含 deleted_at，否则软删除后无法重建同名文档
