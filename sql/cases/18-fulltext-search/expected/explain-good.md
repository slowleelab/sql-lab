# EXPLAIN 参考结果 - good.sql（FULLTEXT + MATCH AGAINST）

## MySQL 8.0（20 万行中文文章，content 建 FULLTEXT ngram 索引）

```
+----+-------------+-----------------------+------------+----------+-----------------+-----------------+---------+-------+------+----------+----------------------------+
| id | select_type | table                 | partitions | type     | possible_keys   | key             | key_len | ref   | rows | filtered | Extra                      |
+----+-------------+-----------------------+------------+----------+-----------------+-----------------+---------+-------+------+----------+----------------------------+
|  1 | SIMPLE      | t_article_search_good | NULL       | fulltext | ft_content      | ft_content      | 0       | const |    1 |   100.00 | Using where; Ft_hints: sorted |
+----+-------------+-----------------------+------------+----------+-----------------+-----------------+---------+-------+------+----------+----------------------------+
```

## 关键改进

| 字段 | 值 | 分析 |
|------|-----|------|
| type | `fulltext` | 走 FULLTEXT 倒排索引 |
| possible_keys | `ft_content` | 优化器识别到全文索引 |
| key | `ft_content` | 命中 FULLTEXT 索引 |
| key_len | `0` | FULLTEXT 索引特殊，key_len 不适用 |
| rows | `1` | 倒排索引直接定位到匹配文档 |
| filtered | 100.00% | 倒排索引结果即最终结果，无需过滤 |
| Extra | `Using where; Ft_hints: sorted` | 走全文索引并按相关性排序 |

## 为什么快

FULLTEXT 索引预建了**倒排索引**（inverted index）。写入数据时，ngram 分词器将中文按 token 切分，建立 token -> 文档 ID 列表 的映射：

```
ngram 分词（ngram_token_size=2，默认 2 字符）:
  "性能优化" -> "性能" + "能优" + "优化"

倒排索引结构（示意）:
  "性能" -> [doc_id: 1, 42, 198, 5003, 50204, ...]
  "能优" -> [doc_id: 1, 42, 198, 5003, 50204, ...]
  "优化" -> [doc_id: 1, 5, 42, 198, 50204, ...]

查询 '性能优化' IN BOOLEAN MODE:
  → 取 "性能" "能优" "优化" 三个 token 的倒排链
  → 求交集（BOOLEAN MODE 默认 AND 语义）
  → 直接得到同时包含三个 token 的文档 ID 列表        ← O(1) 级别
```

与 LIKE 的关键差异：
- **LIKE**：逐行读取 content 全文做子串匹配，O(n) 全表扫描
- **FULLTEXT**：查询时只查倒排索引定位文档，O(1) 级别，content 全文仅在回表展示时读取

实际耗时约 **15 ms**。

## ngram_token_size 参数说明

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `ngram_token_size` | `2` | ngram 分词的 token 长度（字符数） |

- 默认 `ngram_token_size=2`，将中文按 2 字符切分。"性能优化" -> "性能"、"能优"、"优化"
- 查询词长度必须 >= `ngram_token_size` 才能命中索引。查单个字（如"优"）无法走 FULLTEXT，退化为全表扫描
- 该参数是**只读启动参数**，需在 my.cnf 中设置 `ngram_token_size=2`（或 1）后重启生效，不能动态修改
- 查看当前值：`SHOW VARIABLES LIKE 'ngram_token_size';`

## 量化对比

| 指标 | bad.sql (LIKE) | good.sql (FULLTEXT) | 提升 |
|------|---------------|---------------------|------|
| type | ALL | fulltext | - |
| key | NULL | ft_content | 索引生效 |
| rows | ~199,687 | 1 | 减少 99.999% |
| 扫描方式 | 全表逐行子串匹配 | 倒排索引查找 | O(n) -> O(1) |
| 耗时 | ~3,200 ms | ~15 ms | **213 倍** |

## 5.7 vs 8.0 差异

- 5.7.6+ 开始支持 InnoDB FULLTEXT + ngram 分词器，EXPLAIN 输出 `type=fulltext`
- 8.0 对 FULLTEXT 查询做了优化（Ft_hints、并行构建等），构建索引速度更快
- 两版 `ngram_token_size` 默认值均为 2，行为一致
- 5.7 EXPLAIN 的 Extra 可能不含 `Ft_hints: sorted`，但 type=fulltext 表现相同
