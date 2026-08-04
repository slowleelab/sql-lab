# 大字段垂直拆表

<CaseMeta difficulty="⭐⭐" category="DDL" versions="5.7 & 8.0" :tags="['TEXT', 'BLOB', '垂直拆分', 'Buffer Pool', '冷热分离']" />

## TEXT 正文拖慢列表页：垂直拆分 45ms 到毫秒级
内容管理系统的文章表，正文 `content TEXT`（平均 5KB）和标题、作者等元数据混在同一张表。列表页只需要标题和摘要，查询已走索引、也不查 `content` 字段，但响应仍要 **45ms**。

```sql
-- 列表页：不需要 content，但表里有 TEXT
SELECT id, title, author, category, views, created_at
FROM t_article_bad
WHERE category = '技术'
ORDER BY created_at DESC
LIMIT 20;
```

案例 32 演示了用"只查必要列"避免读取 TEXT 溢出页。但如果 TEXT 字段就在表里，即使不查它，InnoDB 数据页结构仍被 TEXT 拖累--每页只能放 3 行，Buffer Pool 被冷数据挤占。**根本解法是把大字段拆到扩展表**。

::: warning 真实场景
任何把大字段和元数据混在一张表的场景：文章正文、商品详情富文本、日志原文、JSON 报文体。只要列表/统计查询访问这张表，大字段就会拖慢整体性能--不是因为你查了它，而是因为它让每页能放的行变少了。
:::

## 问题分析

### bad.sql

```sql
-- 正文和元数据混在一张表
CREATE TABLE t_article_bad (
    id           BIGINT        NOT NULL AUTO_INCREMENT,
    title        VARCHAR(200)  NOT NULL,
    author       VARCHAR(50)   NOT NULL,
    category     VARCHAR(20)   NOT NULL,
    views        INT           NOT NULL DEFAULT 0,
    content      TEXT          NOT NULL,   -- 平均 5KB
    created_at   DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    KEY idx_category_created (category, created_at)
) ENGINE=InnoDB;

-- 列表查询：不查 content，但表结构有 TEXT
SELECT id, title, author, category, views, created_at
FROM t_article_bad
WHERE category = '技术'
ORDER BY created_at DESC
LIMIT 20;
```

### 表大小

```
+----------------+------------+---------+
| TABLE_NAME     | TABLE_ROWS | data_mb |
+----------------+------------+---------+
| t_article_bad  |     100000 |  512.34 |  -- 10 万行占 512 MB
+----------------+------------+---------+
```

### 为什么慢

问题不在 SQL 写法（已走索引、未查 TEXT），而在**表物理结构**：

```
InnoDB 页大小 16KB

bad 表每行约 5KB（含 TEXT 指针 + 行内数据）
→ 每页只能放 3 行
→ 取 20 行需读取约 7 个数据页
→ 512 MB 表大量占用 Buffer Pool
→ 列表查询的元数据页被 TEXT 冷数据挤走
→ Buffer Pool 命中率低，磁盘 I/O 增加
```

即使不查 `content` 字段，回表到聚簇索引时仍需加载包含 TEXT 相关数据的完整数据页。TEXT 的存在让数据页变得"稀疏"，同样数量的行占用更多页。

::: tip 核心认知
大字段的问题不在"被查询时慢"，而在"存在于表中就慢"。它让每页可容纳的行数急剧减少，影响所有访问该表的查询。拆表是把"热数据"（元数据）和"冷数据"（正文）物理隔离，让热数据页更紧凑。
:::

## 优化方案

### good.sql

```sql
-- 1. 主表：只存元数据（热数据）
CREATE TABLE t_article_good (
    id           BIGINT        NOT NULL AUTO_INCREMENT,
    title        VARCHAR(200)  NOT NULL,
    author       VARCHAR(50)   NOT NULL,
    category     VARCHAR(20)   NOT NULL,
    views        INT           NOT NULL DEFAULT 0,
    created_at   DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    KEY idx_category_created (category, created_at)
) ENGINE=InnoDB;

-- 2. 扩展表：单独存正文（冷数据）
CREATE TABLE t_article_content (
    article_id   BIGINT        NOT NULL,
    content      MEDIUMTEXT    NOT NULL,
    PRIMARY KEY (article_id)
) ENGINE=InnoDB;

-- 列表查询：只查主表，每页 80 行，28.5 MB 可常驻 Buffer Pool
SELECT id, title, author, category, views, created_at
FROM t_article_good
WHERE category = '技术'
ORDER BY created_at DESC
LIMIT 20;

-- 详情查询：JOIN 扩展表取正文
SELECT a.id, a.title, a.author, a.category, a.views, c.content, a.created_at
FROM t_article_good a
LEFT JOIN t_article_content c ON a.id = c.article_id
WHERE a.id = 1;
```

### 原理

拆表后，主表每行约 0.2KB（无 TEXT），数据页结构发生根本变化：

| | bad（混合表） | good（拆表后） |
|---|---|---|
| 每行大小 | ~5 KB | ~0.2 KB |
| 每页行数 | ~3 行 | ~80 行 |
| 主表总大小 | 512 MB | **28.5 MB** |
| 取 20 行扫描页数 | ~7 页 | ~1 页 |
| Buffer Pool 命中率 | ~70% | **~99%** |

28.5 MB 的主表可以完全常驻 Buffer Pool，列表查询几乎纯内存操作。正文（485 MB）只在详情页按主键精确读取，不污染列表查询的缓存。

### 对比

| | bad (混合表) | good (拆表后) |
|---|---|---|
| 主表大小 | 512 MB | 28.5 MB |
| 每页行数 | ~3 | ~80 |
| 列表查询耗时 | ~45 ms | **~8 ms** |
| 详情页耗时 | ~5 ms | ~6 ms（多一次 JOIN） |
| Buffer Pool 命中率 | ~70% | ~99% |

<ExplainCompare
  :bad="{ type: 'ref', key: 'idx_category_created', rows: '20,000', Extra: '每页3行，扫描7个数据页，512MB表占Buffer Pool' }"
  :good="{ type: 'ref', key: 'idx_category_created', rows: '20,000', Extra: '每页80行，扫描1个数据页，28.5MB常驻Buffer Pool' }"
  improvement="主表缩小 94%，每页行数提升 27 倍，列表查询提速 5.6 倍"
/>

## 避坑指南

::: warning 注意事项

1. **什么字段该拆**。TEXT、BLOB、MEDIUMTEXT、LONGTEXT 以及超长 VARCHAR（如 4000+ 字符的 JSON 字段）。判断标准：字段平均大小远大于其他字段，且不是每次查询都需要。

2. **详情页的 JOIN 代价**。拆表后详情查询多一次 JOIN，但 `type=eq_ref`（主键关联）代价极小（1 次 B+ 树查找）。如果详情页访问频率很高，可考虑缓存正文到 Redis。

3. **不要拆得太碎**。垂直拆表一般拆成 2 张（主表 + 扩展表）即可。拆成 3 张以上会增加 JOIN 复杂度，得不偿失。

4. **迁移现有表的方案**。用 `pt-online-schema-change` 创建新表 + 同步数据 + 原子切换。不要直接 `ALTER TABLE`，大表会锁很久。

5. **与案例 32 的关系**。案例 32 解决"已经有大字段表，如何避免 SELECT * 读溢出页"的问题（不改表结构）；本案例解决"从根本上把大字段拆出去"的问题（改表结构）。如果表已经存在 TEXT 且无法改结构，先用案例 32 的方案；新表设计或可重构时，用本案例的方案。
:::

## 5.7 vs 8.0 差异

| 特性 | 5.7 | 8.0 |
|------|-----|-----|
| 默认行格式 | DYNAMIC | DYNAMIC |
| TEXT 存储机制 | 溢出页 | 溢出页（一致） |
| 垂直拆表效果 | ✅ 有效 | ✅ 有效 |
| Buffer Pool 管理 | 基础 LRU | 改进版 LRU（更智能） |

::: tip 两版通用
垂直拆表是物理设计层面的优化，与 MySQL 版本无关。5.7 和 8.0 的 DYNAMIC 行格式下，TEXT 都存溢出页，拆表后主表紧凑度提升一致。8.0 的 Buffer Pool 管理更智能，拆表后命中率提升略明显。
:::

## 本地复现

```bash
# 默认在 MySQL 8.0 上运行
./scripts/run-case.sh 50-vertical-split-text

# 在 MySQL 5.7 上运行（对比）
./scripts/run-case.sh 50-vertical-split-text --ver 5.7

# 跳过造数据重跑
./scripts/run-case.sh 50-vertical-split-text --no-seed
```
