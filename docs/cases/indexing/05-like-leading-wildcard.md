# LIKE 前导通配符致索引失效

<CaseMeta difficulty="⭐" category="索引" versions="5.7 & 8.0" :tags="['LIKE', '通配符', '索引失效']" />

## 20 万：用户搜索框输入关键词
用户搜索框输入关键词，后端用 `LIKE '%zhang%'` 模糊查询。`username` 字段有索引，但 20 万行全表扫描。

## 问题分析

```sql
-- bad.sql: 前导通配符 % 使索引失效
SELECT id, username, nickname, phone, created_at
FROM t_user_search
WHERE username LIKE '%zhang%';
```

EXPLAIN: `type=ALL`, `key=NULL` -- 全表扫描。

**原因**：B+ 树按字母顺序排列。前导 `%` 意味着无法确定扫描起点（匹配可能出现在任何位置），只能逐行扫描做子串匹配。

## 优化方案

```sql
-- good.sql: 后导通配符，B+ 树可定位 'zhang' 前缀起点
SELECT id, username, nickname, phone, created_at
FROM t_user_search
WHERE username LIKE 'zhang%';
```

EXPLAIN: `type=range`, `key=idx_username` -- 走索引范围扫描。

<ExplainCompare
  :bad="{ type: 'ALL', key: 'NULL', rows: '200,000', Extra: 'Using where' }"
  :good="{ type: 'range', key: 'idx_username', rows: '~50', Extra: 'Using index condition' }"
  improvement="前导% -> 后导%，索引恢复范围扫描"
/>

::: warning 注意
`'zhang%'` 只匹配以 zhang **开头**的用户名，语义与 `'%zhang%'`（**包含** zhang）不同。若业务确需包含匹配，考虑：
1. MySQL FULLTEXT 全文索引
2. Elasticsearch / MeiliSearch 等外部搜索引擎
3. 如必须用 LIKE '%x%'，接受全表扫描但限制结果集 `LIMIT`
:::

## 避坑指南

::: warning 注意事项
1. `'keyword%'`（后导%）走索引 ✅
2. `'%keyword'`（前导%）不走索引 ❌
3. `'%keyword%'`（双向%）不走索引 ❌
4. `LIKE CONCAT(?, '%')` 动态拼接时，参数在前也走索引 ✅
:::

## 本地复现

```bash
./scripts/run-case.sh 05-like-leading-wildcard
```
