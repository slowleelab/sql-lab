# JSON 字段使用模式

<CaseMeta difficulty="⭐⭐" category="架构级优化" versions="8.0" :tags="['JSON', '虚拟列', '函数索引', '8.0新特性']" />

## 10 万慢：按颜色筛选商品却慢到 45ms
商品属性灵活多变，团队用 JSON 字段 `attrs` 存储 `{"color":"red","size":"L","brand":"Nike"}` 这类属性。上线后商品表 10 万行，按颜色筛选商品却慢到 **45ms**：

```sql
SELECT *
FROM t_product_json
WHERE JSON_EXTRACT(attrs, '$.color') = 'red';
```

看起来逻辑简单清晰，`attrs` 列上也没有索引可用。问题在于 `JSON_EXTRACT` 是函数表达式，MySQL 无法直接在 JSON 列上用 B+ 树索引定位，只能逐行解析 JSON 再比较--10 万行全部扫描，即使只有约 1.6 万行匹配 color='red'，也必须读完所有行。

这就是 **"JSON 字段直接查询"** 的经典陷阱--JSON 字段本身不可索引，直接查 JSON 内部键等于全表扫描。数据量越大越严重，百万行表上同类查询可达数百毫秒甚至秒级。

::: warning 真实场景
商品扩展属性、用户标签、日志详情、配置信息--凡是用 JSON 存储且需要按内部字段查询的场景，直接 `JSON_EXTRACT` 查询都会全表扫描。`attrs->'$.color'` 和 `attrs->>'$.color'` 只是语法糖，等价于 `JSON_EXTRACT`，同样全表扫描。常见误区是"JSON 灵活方便，直接查就行"，殊不知 JSON 字段本身不可索引。
:::

## 问题分析

### bad.sql

```sql
-- bad.sql: 直接用 JSON_EXTRACT 查询 JSON 内部字段（全表扫描）
-- JSON_EXTRACT 是函数，无法直接在 attrs 上走索引，需逐行解析 JSON 再比较
SELECT *
FROM t_product_json
WHERE JSON_EXTRACT(attrs, '$.color') = 'red';
```

### EXPLAIN 结果

```
+----+-------------+-----------------+------------+------+---------------+------+---------+------+--------+----------+-------------+
| id | select_type | table           | partitions | type | possible_keys | key  | key_len | ref  | rows   | filtered | Extra       |
+----+-------------+-----------------+------------+------+---------------+------+---------+------+--------+----------+-------------+
|  1 | SIMPLE      | t_product_json  | NULL       | ALL  | NULL          | NULL | NULL    | NULL | 99564  |   100.00 | Using where |
+----+-------------+-----------------+------------+------+---------------+------+---------+------+--------+----------+-------------+
```

### 为什么慢

1. **JSON 函数无法走索引**：`JSON_EXTRACT(attrs, '$.color')` 是函数表达式，MySQL 无法直接在 JSON 列 `attrs` 上用 B+ 树索引定位
2. **逐行解析 JSON**：每一行都要调用 JSON 解析器提取 `$.color`，再与 `'red'` 比较，CPU 开销大
3. **全表扫描**：10 万行全部扫描，即使只有约 1.6 万行（1/6）匹配 color='red'，也必须读完所有行
4. **SELECT \* 回表且全读**：所有行的完整数据都要读取，I/O 代价高
5. **数据量大时线性恶化**：100 万行就要扫描 100 万行，1000 万行就扫描 1000 万行，无法靠索引缩小范围

::: tip 核心认知
JSON 字段本身不可索引。要把高频查询的 JSON 键提取为**虚拟列（Generated Column）**并建索引，让 JSON 内部字段的等值/范围查询走索引。这是 MySQL 8.0 处理 JSON 查询性能问题的标准方案。
:::

## 优化方案

### good.sql

```sql
-- good.sql: 通过虚拟列 color 走索引查询（需先执行 setup-good.sql 建虚拟列+索引）
-- 虚拟列 color 由 attrs->'$.color' 派生，查询时直接走 idx_color 索引
-- 也可写成 WHERE attrs->'$.color' = 'red'，优化器会自动匹配虚拟列索引
SELECT *
FROM t_product_json
WHERE color = 'red';
```

### 建索引语句

```sql
-- setup-good.sql: 为 JSON 字段建虚拟列 + 索引（MySQL 8.0）
-- 将 attrs->'$.color' 提取为虚拟列 color，并在其上建索引
-- 虚拟列不占存储空间（VIRTUAL），索引基于虚拟列值构建
ALTER TABLE t_product_json
    ADD COLUMN color VARCHAR(20)
        GENERATED ALWAYS AS (JSON_UNQUOTE(JSON_EXTRACT(attrs, '$.color'))) VIRTUAL,
    ADD KEY idx_color (color);
```

> 需先执行 `setup-good.sql` 创建虚拟列 `color` 及索引 `idx_color`，再执行 `good.sql`。

### 原理

虚拟列 `color` 由 `JSON_UNQUOTE(JSON_EXTRACT(attrs, '$.color'))` 自动计算，值与 JSON 内部字段同步。`idx_color` 是建立在虚拟列上的普通 B+ 树索引，查询时直接用索引定位：

```
attrs JSON: {"color":"red","size":"L","brand":"Nike"}
                              ↓ JSON_UNQUOTE(JSON_EXTRACT(attrs, '$.color'))
虚拟列 color: "red"  ──→  idx_color B+树索引
                              ↓ WHERE color = 'red'
                         索引等值查找（type=ref）
```

1. **虚拟列派生自 JSON**：`color` 列由 `JSON_UNQUOTE(JSON_EXTRACT(attrs, '$.color'))` 自动计算，值与 JSON 内部字段同步
2. **索引基于虚拟列**：`idx_color` 是建立在虚拟列上的普通 B+ 树索引，查询时直接用索引定位
3. **VIRTUAL 不占存储**：虚拟列 `VIRTUAL` 不实际存储列值，只在读取时计算；索引中存储计算后的值，兼顾查询性能与存储
4. **优化器自动改写**：即使写成 `WHERE attrs->'$.color' = 'red'`，8.0 优化器也能识别并匹配到虚拟列索引（等价改写）
5. **避免逐行解析**：索引已预先计算好 color 值，无需运行时解析 JSON

::: tip 虚拟列 vs 函数索引（8.0.13+）
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
:::

### 对比

| 指标 | bad (JSON_EXTRACT) | good (虚拟列+索引) | 提升 |
|------|--------------------|--------------------|------|
| type | ALL（全表扫描） | ref（索引查找） | 走索引 |
| rows | ~99,564 | ~31,776 | **减少 68%** |
| Extra | Using where | NULL | 无额外开销 |
| 耗时 | ~45 ms | ~8 ms | **约 5.6 倍** |

<ExplainCompare
  :bad="{ type: 'ALL', key: 'NULL', rows: '99,564', Extra: 'Using where（逐行解析 JSON，全表扫描）' }"
  :good="{ type: 'ref', key: 'idx_color', rows: '31,776', Extra: 'NULL（虚拟列索引直接定位，无需运行时解析）' }"
  improvement="从全表扫描 10 万行降为索引查找，耗时下降约 5.6 倍"
/>

> rows 为优化器预估值。实测 bad 全表扫描 10 万行，good 通过 idx_color 实际命中约 16,730 行（color='red' 占约 1/6）。数据量越大差距越显著：百万行表上，bad 方案扫描百万行，good 方案仍只扫描匹配的约 1/6。

## 避坑指南

::: warning 注意事项

1. **只对高频查询键建虚拟列**：不要为 JSON 中所有键都建虚拟列索引，维护成本高且影响写入性能。

2. **注意 JSON 键缺失**：若某行没有 `$.color` 键，虚拟列值为 NULL，等值查询不会匹配（需用 `IS NULL` 另查）。

3. **JSON_UNQUOTE 去引号**：`JSON_EXTRACT` 返回带引号的字符串，比较时需 `JSON_UNQUOTE` 去引号，否则 `'red'` 匹配不到 `'"red"'`。

4. **虚拟列类型要对齐**：虚拟列类型（VARCHAR(20)）要能容纳 JSON 中对应键的所有可能值，否则截断导致查询不准。

5. **写入性能影响**：虚拟列索引会随数据写入维护，高频写入场景需评估写入性能下降。

6. **考虑改用关系表**：若 JSON 中大部分键都需要索引查询，说明数据模型不适合 JSON，应拆成关系表（列或关联表）。
:::

## 5.7 vs 8.0 差异

| 特性 | 5.7 | 8.0 |
|------|-----|-----|
| 生成列（VIRTUAL/STORED） | ✅ 支持 | ✅ 支持 |
| JSON 函数性能 | 较弱 | 显著优化 |
| 优化器自动改写 | ❌ 弱 | ✅ 强（匹配虚拟列索引） |
| 函数索引 | ❌ 不支持 | ✅ 支持（8.0.13+） |
| 虚拟列 + 索引方案 | ✅ 可用 | ✅ 推荐 |

::: tip 版本说明
本案例为 8.0 专属特性。5.7 也支持生成列（VIRTUAL/STORED）并可在其上建索引，但 JSON 函数性能和优化器改写能力弱于 8.0。8.0.13+ 额外支持函数索引，无需显式建虚拟列，写法更简洁。生产实践中推荐 8.0 环境。
:::

## 本地复现

```bash
# 默认在 MySQL 8.0 上运行
./scripts/run-case.sh 57-json-column-pattern

# 在 MySQL 5.7 上运行（对比）
./scripts/run-case.sh 57-json-column-pattern --ver 5.7

# 跳过造数据重跑
./scripts/run-case.sh 57-json-column-pattern --no-seed
```
