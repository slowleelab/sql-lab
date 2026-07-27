# EXPLAIN 参考结果 - good.sql (虚拟列 + 索引)

## MySQL 8.0（执行 setup-good.sql 后，t_product_json 增加虚拟列 color + idx_color）

```
+----+-------------+-----------------+------------+------+---------------+-----------+---------+-------+--------+----------+-------+
| id | select_type | table           | partitions | type | possible_keys | key       | key_len | ref   | rows   | filtered | Extra |
+----+-------------+-----------------+------------+------+---------------+-----------+---------+-------+--------+----------+-------+
|  1 | SIMPLE      | t_product_json  | NULL       | ref  | idx_color     | idx_color | 83      | const |  31302 |   100.00 | NULL  |
+----+-------------+-----------------+------------+------+---------------+-----------+---------+-------+--------+----------+-------+
```

## 关键改进

| 字段 | 值 | 分析 |
|------|-----|------|
| type | `ref` | **走索引**等值查找 |
| possible_keys | `idx_color` | 优化器识别到虚拟列索引可用 |
| key | `idx_color` | 使用虚拟列 color 上的索引 |
| key_len | 83 | VARCHAR(20) utf8mb4 + NULL 标记位等值匹配 |
| rows | ~31,302 | 预估扫描行数（统计值，实测实际命中约 16,616 行） |
| Extra | `NULL` | 无 filesort、无回表过滤，直接索引定位 |

## 为什么快

1. **虚拟列派生自 JSON**：`color` 列由 `JSON_UNQUOTE(JSON_EXTRACT(attrs, '$.color'))` 自动计算，值与 JSON 内部字段同步
2. **索引基于虚拟列**：`idx_color` 是建立在虚拟列上的普通 B+ 树索引，查询时直接用索引定位
3. **VIRTUAL 不占存储**：虚拟列 `VIRTUAL` 不实际存储列值，只在读取时计算；索引中存储计算后的值，兼顾查询性能与存储
4. **优化器自动改写**：即使写成 `WHERE attrs->'$.color' = 'red'`，8.0 优化器也能识别并匹配到虚拟列索引（等价改写）
5. **避免逐行解析**：索引已预先计算好 color 值，无需运行时解析 JSON

### 虚拟列 vs 函数索引（8.0.13+）

MySQL 8.0.13 起支持**函数索引**（Functional Index），可直接对表达式建索引，无需显式建虚拟列：

```sql
-- 方式一: 虚拟列 + 普通索引（本案例方案，8.0 全版本支持）
ALTER TABLE t_product_json
    ADD COLUMN color VARCHAR(20)
        GENERATED ALWAYS AS (JSON_UNQUOTE(JSON_EXTRACT(attrs, '$.color'))) VIRTUAL,
    ADD KEY idx_color (color);

-- 方式二: 函数索引（8.0.13+，更简洁）
ALTER TABLE t_product_json
    ADD KEY idx_color_fn ((CAST(JSON_UNQUOTE(JSON_EXTRACT(attrs, '$.color')) AS CHAR(20))));
```

两者效果类似，函数索引更简洁但要求 8.0.13+；虚拟列方案兼容性更好且可复用列（SELECT 时可直接用 color）。

### STORED vs VIRTUAL 虚拟列

| 类型 | 存储空间 | 计算时机 | 适用场景 |
|------|----------|----------|----------|
| VIRTUAL | 不占空间 | 读取时计算 | 读多写少、计算简单（推荐，本案例） |
| STORED | 占空间 | 写入时计算并存储 | 计算复杂、读取频繁、需在列上建二级索引 |

## 量化对比

| 指标 | bad (JSON_EXTRACT) | good (虚拟列+索引) | 提升 |
|------|--------------------|--------------------|------|
| type | ALL（全表扫描） | ref（索引查找） | 走索引 |
| rows | ~100,000 | ~31,302 | **减少 69%** |
| Extra | Using where | NULL | 无额外开销 |
| 耗时 | ~45 ms | ~8 ms | **约 5.6 倍** |

> rows 为优化器预估值。实测 bad 全表扫描 10 万行，good 通过 idx_color 实际命中约 16,616 行（color='red' 占约 1/6）。
> 数据量越大差距越显著。百万行表上，bad 方案扫描百万行，good 方案仍只扫描匹配的约 1/6。

### 关于 8.0 优化器的自动改写

MySQL 8.0 优化器较聪明：当虚拟列 `color` 与索引 `idx_color` 已存在时，即便 SQL 仍写成 `WHERE JSON_EXTRACT(attrs, '$.color') = 'red'`（bad.sql 的写法），优化器也可能将其**等价改写**为对虚拟列的访问，从而命中 `idx_color`。

因此本案例的对比前提是：**bad 方案在未建立虚拟列/索引时执行**（此时确为全表扫描 ALL）。`run-case.sh` 先跑 bad（无索引）再跑 setup-good + good，可正确呈现差异。生产实践中，虚拟列索引就是为高频 JSON 查询准备的--建好之后，无论写 `JSON_EXTRACT` 还是直接引用虚拟列，优化器都能走索引。

## 8.0 专属说明

本案例依赖 MySQL 8.0 特性：
- **生成列（Generated Column）**：5.7 已支持 VIRTUAL/STORED 生成列，可建索引
- **JSON 路径表达式优化**：8.0 对 JSON 查询有显著优化
- **函数索引**：8.0.13+ 支持，无需显式建虚拟列
- 5.7 也可用虚拟列方案（生成列 5.7 引入），但 JSON 函数性能和优化器改写能力弱于 8.0

## 避坑指南

1. **只对高频查询键建虚拟列**：不要为 JSON 中所有键都建虚拟列索引，维护成本高且影响写入性能
2. **注意 JSON 键缺失**：若某行没有 `$.color` 键，虚拟列值为 NULL，等值查询不会匹配（需用 `IS NULL` 另查）
3. **JSON_UNQUOTE 去引号**：`JSON_EXTRACT` 返回带引号的字符串，比较时需 `JSON_UNQUOTE` 去引号，否则 `'red'` 匹配不到 `'"red"'`
4. **虚拟列类型要对齐**：虚拟列类型（VARCHAR(20)）要能容纳 JSON 中对应键的所有可能值，否则截断导致查询不准
5. **写入性能影响**：虚拟列索引会随数据写入维护，高频写入场景需评估写入性能下降
6. **考虑改用关系表**：若 JSON 中大部分键都需要索引查询，说明数据模型不适合 JSON，应拆成关系表（列或关联表）
7. **JSON 适合的场景**：属性灵活多变、整体读取多、按内部键查询少（如商品扩展属性、日志详情）
