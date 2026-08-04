# 全文索引 FULLTEXT 替代 LIKE

<CaseMeta difficulty="⭐⭐" category="索引" versions="5.7 & 8.0" :tags="['FULLTEXT', 'ngram', '全文检索', 'LIKE', '中文搜索']" />

## 正文搜索 LIKE '%关键词%'：换 FULLTEXT 还是别的
内容管理系统、知识库、论坛等场景中，用户输入关键词搜索文章正文。最常见的写法是用 `LIKE '%关键词%'`：

```sql
SELECT id, title, author, content, category
FROM t_article
WHERE content LIKE '%性能优化%';
```

当文章表只有几十万行时，这个查询就已经要跑好几秒。到了百万级数据，搜索接口直接超时。问题根源是 `content` 正文字段没有合适的索引，`LIKE '%...%'` 的前导通配符让任何 B+ 树索引都失效，只能全表扫描逐行做子串匹配。

很多团队最终的"解决方案"是引入 Elasticsearch，但这意味着额外的运维成本和数据同步复杂度。其实在**纯 MySQL 环境下**，FULLTEXT 索引 + ngram 分词器就能把中文全文搜索做到毫秒级。

::: warning 真实场景
内容搜索、日志检索、知识库搜索等"在长文本中找关键词"的场景，`LIKE '%关键词%'` 是性能杀手。前导通配符导致全表扫描，数据量越大越慢，且无法通过加普通索引解决。
:::

## 问题分析

### bad.sql

```sql
SELECT id, title, author, content, category
FROM t_article_search_bad
WHERE content LIKE '%性能优化%';
```

### EXPLAIN 结果

```
+----+-------------+----------------------+------------+------+---------------+------+---------+------+--------+----------+-------------+
| id | select_type | table                | partitions | type | possible_keys | key  | key_len | ref  | rows   | filtered | Extra       |
+----+-------------+----------------------+------------+------+---------------+------+---------+------+--------+----------+-------------+
|  1 | SIMPLE      | t_article_search_bad | NULL       | ALL  | NULL          | NULL | NULL    | NULL | 199687 |    11.11 | Using where |
+----+-------------+----------------------+------------+------+---------------+------+---------+------+--------+----------+-------------+
```

### 为什么慢

`type=ALL` 全表扫描，20 万行逐行处理。前导通配符 `%` 是核心问题：

```
MySQL 执行流程:
1. 全表扫描 t_article_search_bad 的 20 万行                ← O(n)
2. 对每行读取 content（TEXT 可能存储在溢出页，需额外 I/O）
3. 在 content 中做子串匹配，判断是否包含 '性能优化'
4. 命中的行加入结果集
```

**前导通配符为什么无法走索引？** B+ 树索引按字段值有序排列。`LIKE '性能优化%'`（后导通配符）可以定位到以"性能优化"开头的位置向后扫描；但 `LIKE '%性能优化%'`（前导通配符）意味着关键词可能出现在任意位置，B+ 树无法确定扫描起点，只能放弃索引。

更糟的是，`content` 是 TEXT 类型，长正文存储在行外溢出页。每行匹配时都要额外读取溢出页，I/O 放大严重。实际耗时约 **3.2 秒**。

::: tip 核心认知
`LIKE '%关键词%'` 的前导 `%` 让任何普通索引失效。普通 B+ 树索引解决不了"文本中任意位置包含某词"的搜索需求。这种场景必须用全文索引（倒排索引）或外部搜索引擎。
:::

## 优化方案

### good.sql

```sql
SELECT id, title, author, content, category
FROM t_article_search_good
WHERE MATCH(content) AGAINST('性能优化' IN BOOLEAN MODE);
```

建索引的 DDL：

```sql
ALTER TABLE t_article_search_good
  ADD FULLTEXT INDEX ft_content (content) WITH PARSER ngram;
```

### 原理

FULLTEXT 索引在底层构建的是**倒排索引**（inverted index）--与普通 B+ 树索引完全不同的数据结构：

```
普通 B+ 树索引:  行 -> 字段值（正向查找，适合等值/范围）
倒排索引:        词(token) -> 文档ID列表（反向查找，适合全文搜索）
```

**ngram 分词器**是 MySQL 5.7.6+ 内置插件，专门解决中文分词问题。默认 `ngram_token_size=2`，将中文按 2 字符切分：

```
写入时（建倒排索引）:
  "性能优化实战指南"
  -> ngram 切分: "性能" + "能优" + "优化" + "化实" + "实战" + "战指" + "指南"
  -> 每个 token 记录所属文档 ID

  倒排索引（示意）:
    "性能" -> [doc_id: 1, 42, 198, 5003, 50204, ...]
    "能优" -> [doc_id: 1, 42, 198, 5003, 50204, ...]
    "优化" -> [doc_id: 1, 5, 42, 198, 50204, ...]

查询时（MATCH AGAINST）:
  '性能优化' -> ngram 切分: "性能" + "能优" + "优化"
  -> 取三个 token 的倒排链
  -> 求交集（BOOLEAN MODE 默认 AND 语义）
  -> 直接得到同时包含三个 token 的文档 ID 列表     ← O(1) 级别
```

**IN BOOLEAN MODE** 提供精确的布尔查询语义，支持操作符：

| 操作符 | 含义 | 示例 |
|--------|------|------|
| （无） | 必须包含（AND） | `AGAINST('性能 优化')` 两个词都要有 |
| `+` | 必须包含 | `AGAINST('+性能 +优化')` |
| `-` | 必须不包含 | `AGAINST('+性能 -缓存')` 含性能不含缓存 |
| `*` | 前缀通配 | `AGAINST('性能*')` 匹配性能开头的词 |
| `"..."` | 精确短语 | `AGAINST('"性能优化"')` 整体匹配 |

本例用 `AGAINST('性能优化' IN BOOLEAN MODE)`，ngram 切分后三个 token 做 AND，语义上最接近 `LIKE '%性能优化%'`。

### 对比

| | bad.sql (LIKE) | good.sql (FULLTEXT) |
|---|---|---|
| type | ALL | fulltext |
| key | NULL | ft_content |
| 扫描方式 | 全表逐行子串匹配 | 倒排索引查找 |
| 时间复杂度 | O(n) | O(1) 级别 |
| rows | ~199,687 | 1 |
| 耗时 | ~3,200 ms | ~15 ms |

<ExplainCompare
  :bad="{ type: 'ALL', key: 'NULL', rows: '199,687', Extra: 'Using where' }"
  :good="{ type: 'fulltext', key: 'ft_content', rows: '1', Extra: 'Using where; Ft_hints: sorted' }"
  improvement="全表扫描转为倒排索引查找，扫描行数从 20 万降至 1，耗时下降 99.5%（213 倍）"
/>

## 避坑指南

::: warning 注意事项

1. **ngram_token_size 是只读启动参数**。默认值为 2，需在 `my.cnf` 中配置 `ngram_token_size=2`（或 1）后重启 MySQL 生效，不能通过 `SET GLOBAL` 动态修改。查看当前值用 `SHOW VARIABLES LIKE 'ngram_token_size';`。改这个参数会影响所有 FULLTEXT ngram 索引的分词方式，修改后需重建索引。

2. **查询词长度受 ngram_token_size 限制**。查询词必须 >= `ngram_token_size` 才能走 FULLTEXT 索引。默认 token_size=2 时，搜索单个字（如"优"）无法命中倒排索引，会退化为全表扫描。如果业务有单字搜索需求，考虑设 `ngram_token_size=1`。

3. **最小词长 ft_min_word_len / innodb_ft_min_token_size**。这两个参数控制索引的最小词长（默认 InnoDB 为 3，MyISAM 为 4）。对英文分词有效，ngram 中文分词由 `ngram_token_size` 单独控制。配置变更后需重建 FULLTEXT 索引。

4. **中文分词的局限性**。ngram 是机械切分，不理解语义。"上海市" 会被切成"上海" + "海市"，搜"海市"也能命中。对分词精度要求高的场景（如搜索"数据库"不想匹配"数据仓库"），ngram 会有噪音，需要专业分词器或 Elasticsearch。

5. **FULLTEXT 不适合所有场景**。高频更新的大表上，FULLTEXT 索引的维护开销较大（每次写入都要更新倒排索引）。对于实时性要求极高或数据量过亿的场景，Elasticsearch 等专用搜索引擎仍是更好的选择。FULLTEXT 适合中小规模（百万级以内）的纯 MySQL 方案。

6. **BOOLEAN MODE 与 NATURAL LANGUAGE MODE 区别**。`NATURAL LANGUAGE MODE`（默认）按相关性排序返回，适合"搜索框"；`BOOLEAN MODE` 支持操作符精确控制，适合"高级搜索"。本例用 BOOLEAN MODE 是为了精确匹配短语，接近 LIKE 语义。
:::

## 5.7 vs 8.0 差异

| 特性 | 5.7 | 8.0 |
|------|-----|-----|
| InnoDB FULLTEXT + ngram | 5.7.6+ 支持 | 支持 |
| ngram_token_size 默认值 | 2 | 2 |
| FULLTEXT 索引构建 | 支持 | 更快（优化了并行构建） |
| EXPLAIN 输出 | type=fulltext | type=fulltext + Ft_hints |
| 倒排索引缓存 | 基础支持 | `innodb_ft_cache_size` 优化 |

::: tip 8.0 改进
8.0 对 InnoDB FULLTEXT 做了多项优化：索引构建更快、查询计划通过 `Ft_hints` 暴露更多信息、倒排索引缓存管理更智能。5.7.6+ 虽然也支持 ngram 中文分词，但 8.0 在大表上的 FULLTEXT 索引构建速度和查询稳定性明显更好。两版的 `MATCH AGAINST` 语法和 ngram 分词行为一致，迁移无障碍。
:::

## 本地复现

```bash
# 默认在 MySQL 8.0 上运行
./scripts/run-case.sh 18-fulltext-search

# 在 MySQL 5.7 上运行（对比）
./scripts/run-case.sh 18-fulltext-search --ver 5.7

# 跳过造数据重跑
./scripts/run-case.sh 18-fulltext-search --no-seed
```
