# 不可见索引 Invisible Index

<CaseMeta difficulty="⭐⭐" category="索引设计与失效" versions="8.0" :tags="['不可见索引', 'invisible', '安全删索引', '8.0新特性']" />

## 想删索引又怕误伤：不可见索引先探路
商品表按 `category` 查询，`idx_category` 索引正常工作。DBA 怀疑这个索引已经没用了--业务查询都改走了别的索引，`idx_category` 只在白白增加写入开销和占用空间。想删掉它，但又怕有隐藏的慢查询依赖这个索引。

```sql
-- idx_category 可见时，按 category 查询走索引
SELECT id, product_name, category, price
FROM t_product_index
WHERE category = '手机';
```

直接 `DROP INDEX` 风险很大：万一有某个低频但关键的查询依赖该索引，删除后会骤降为全表扫描；删除后再加回索引需要重新构建，大表上耗时且锁表。生产环境很难事先穷举所有受影响的 SQL。

MySQL 8.0 的 INVISIBLE 索引就是解决这个痛点的--先把索引设为不可见，优化器不再使用它，但索引数据仍被维护。观察一段时间确认无影响后再安全删除，若有问题瞬间恢复。

::: warning 真实场景
索引清理是 DBA 最头疼的操作之一。删了怕出事，不删怕浪费。很多公司的表上堆积了大量"可能没用了"的索引，谁也不敢动。INVISIBLE 索引让索引清理从"赌博"变成"可回滚的灰度验证"。
:::

## 问题分析

### bad.sql

```sql
-- bad.sql: idx_category 可见时，按 category 查询走索引
SELECT id, product_name, category, price
FROM t_product_index
WHERE category = '手机';
```

### EXPLAIN 结果

```
+----+-------------+------------------+------+---------------+--------------+---------+-------+------+----------+-------+
| id | select_type | table            | type | possible_keys | key          | key_len | ref   | rows | filtered | Extra |
+----+-------------+------------------+------+---------------+--------------+---------+-------+------+----------+-------+
|  1 | SIMPLE      | t_product_index  | ref  | idx_category  | idx_category | 122     | const | 7482 |   100.00 | NULL  |
+----+-------------+------------------+------+---------------+--------------+---------+-------+------+----------+-------+
```

| 字段 | 值 | 分析 |
|------|-----|------|
| type | `ref` | 等值匹配索引 |
| key | `idx_category` | 正常使用分类索引 |
| key_len | `122` | VARCHAR(30) utf8mb4 = 30×4+2 |
| rows | ~7,482 | 某分类命中约 7500 行 |
| Extra | NULL | 无额外操作 |

### 为什么慢

此时 `idx_category` 可见且被正常使用。查询本身不慢，但 DBA 怀疑这个索引已无用，想删除来节省空间和写入开销。**直接 `DROP INDEX` 风险很大**：

1. 若有隐藏的慢查询依赖该索引，删除后会骤降为全表扫描
2. 删除后再加回索引需要重新构建，耗时且锁表风险
3. 生产环境很难事先穷举所有受影响的 SQL

::: warning 为什么不能直接 DROP INDEX
`DROP INDEX` 是不可逆的破坏性操作。MySQL 5.7 及之前版本删除索引后只能重建，若发现问题需 `ADD INDEX` 重新构建，大表上耗时很久。
:::

::: tip 核心认知
INVISIBLE 索引让索引对优化器"隐身"但数据仍维护，实现零风险验证删除影响。确认无影响后再 DROP，有问题瞬间 VISIBLE 恢复。
:::

## 优化方案

### good.sql

```sql
-- good.sql: idx_category 设为 INVISIBLE 后，模拟"删除索引"的影响
-- 优化器不再使用该索引，退化为全表扫描（用于验证删除是否安全）
-- 需先执行 setup-good.sql 将索引设为不可见
SELECT id, product_name, category, price
FROM t_product_index
WHERE category = '手机';
```

先执行 setup-good.sql 将索引设为不可见：

```sql
-- setup-good.sql: 将 idx_category 设为不可见（MySQL 8.0+）
-- 索引仍被维护，但优化器不再选用它
ALTER TABLE t_product_index ALTER INDEX idx_category INVISIBLE;
```

### 原理

INVISIBLE 索引的机制：索引数据仍被持续维护（INSERT/UPDATE 仍会更新索引），但优化器在生成执行计划时忽略它，就像索引不存在一样。

```
安全删索引流程:
1. ALTER INDEX INVISIBLE  -> 优化器不再使用，但索引仍维护
2. 观察期 1~2 周          -> 监控慢查询日志、EXPLAIN
3. 确认无影响             -> 所有查询都走了更优的替代计划
4. DROP INDEX             -> 真正回收空间和写入开销
5. 若有问题               -> ALTER INDEX VISIBLE 瞬间恢复
```

| 操作 | DROP INDEX | ALTER INDEX INVISIBLE |
|------|-----------|----------------------|
| 索引数据 | 立即删除 | **保留并持续维护** |
| 优化器可见性 | 不可用 | **不可见（忽略）** |
| 写入开销 | 降低（无需维护） | **不变（仍维护）** |
| 恢复方式 | ADD INDEX（重建，慢） | **ALTER VISIBLE（瞬间）** |
| 风险 | 高（不可逆） | **低（可秒级回滚）** |

### 对比

| | bad (索引可见) | good (INVISIBLE) |
|---|---|---|
| type | ref | ALL |
| rows | ~7,482 | ~148,936 |
| 写入开销 | 维护索引 | 仍维护（INVISIBLE 不省写入） |

<ExplainCompare
  :bad="{ type: 'ref', key: 'idx_category', rows: '7,482', Extra: 'NULL' }"
  :good="{ type: 'ALL', key: 'NULL', rows: '148,936', Extra: 'Using where（模拟删除后退化）' }"
  improvement="INVISIBLE 验证删除影响，确认无问题后 DROP 才真正释放开销，有问题可瞬间恢复"
/>

## 避坑指南

::: warning 注意事项

1. **INVISIBLE 不节省写入开销**。索引数据仍被维护，INSERT/UPDATE 仍更新索引。它的价值是零风险验证删除影响，只有最终 `DROP INDEX` 才真正释放写入开销和空间。不要把 INVISIBLE 当成"永久省空间"的手段。

2. **5.7 不支持 INVISIBLE 索引**。5.7 删索引只能直接 DROP，建议先在测试环境充分验证，或使用 pt-online-schema-change 等工具。

3. **观察期要足够长**。有些低频查询（如月报、定时任务）可能一周才跑一次，观察期至少 1~2 周，覆盖完整的业务周期。配合慢查询日志监控。

4. **主键和唯一索引不能设为 INVISIBLE**。只有普通二级索引可以设为不可见，主键和唯一约束的索引必须保持可见。
:::

## 5.7 vs 8.0 差异

| 特性 | 5.7 | 8.0 |
|------|-----|-----|
| INVISIBLE 索引 | ❌ 不支持 | ✅ 支持 |
| 安全删索引灰度验证 | ❌ 只能直接 DROP | ✅ 先 INVISIBLE 后 DROP |
| 索引恢复 | ADD INDEX（重建，慢） | ALTER VISIBLE（瞬间） |
| `SHOW INDEX` 可见性 | 无此字段 | Visible 字段显示 YES/NO |

::: tip 重要区分
INVISIBLE 索引**不节省写入开销**（索引数据仍被维护），它的价值是**零风险验证删除影响**。只有最终 `DROP INDEX` 才真正释放写入开销和空间。
:::

::: warning 5.7 不支持
INVISIBLE 索引是 MySQL 8.0 新特性，5.7 无此功能。5.7 删索引只能直接 DROP，建议先在测试环境充分验证，或使用 pt-online-schema-change 等工具。
:::

## 本地复现

```bash
# 默认在 MySQL 8.0 上运行
./scripts/run-case.sh 13-invisible-index

# 在 MySQL 5.7 上运行（对比）
./scripts/run-case.sh 13-invisible-index --ver 5.7

# 跳过造数据重跑
./scripts/run-case.sh 13-invisible-index --no-seed
```
