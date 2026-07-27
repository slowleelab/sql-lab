# 案例总览

共 **102 个精选案例**，覆盖 MySQL + TiDB 优化的八大核心场景。每个案例都带真实数据，可一键复现。

## 一、索引设计与失效（18 个）

| # | 案例 | 难度 | 版本 |
|---|------|:----:|:----:|
| 01 | [深度分页 LIMIT 大偏移](./indexing/01-deep-pagination) | ⭐⭐ | 5.7 & 8.0 |
| 02 | [联合索引最左前缀失效](./indexing/02-leftmost-prefix) | ⭐ | 5.7 & 8.0 |
| 03 | [隐式类型转换致索引失效](./indexing/03-implicit-type-conversion) | ⭐⭐ | 5.7 & 8.0 |
| 04 | [函数操作致索引失效](./indexing/04-function-on-index) | ⭐⭐ | 5.7 & 8.0 |
| 05 | [LIKE 前导通配符致索引失效](./indexing/05-like-leading-wildcard) | ⭐ | 5.7 & 8.0 |
| 06 | [OR 条件与索引合并](./indexing/06-or-condition) | ⭐⭐ | 5.7 & 8.0 |
| 07 | [范围查询后列索引失效](./indexing/07-range-after-index) | ⭐⭐ | 5.7 & 8.0 |
| 08 | [覆盖索引避免回表](./indexing/08-covering-index) | ⭐⭐ | 5.7 & 8.0 |
| 09 | [索引下推 ICP（Index Condition Pushdown）](./indexing/09-index-condition-pushdown) | ⭐⭐⭐ | 5.6 & 5.7 & 8.0 |
| 10 | [冗余索引清理](./indexing/10-redundant-index-cleanup) | ⭐⭐ | 5.7 & 8.0 |
| 11 | [前缀索引优化长字符串](./indexing/11-prefix-index) | ⭐⭐ | 5.7 & 8.0 |
| 12 | [索引选择性评估](./indexing/12-index-selectivity) | ⭐⭐ | 5.7 & 8.0 |
| 13 | [不可见索引 Invisible Index](./indexing/13-invisible-index) | ⭐⭐ | 8.0+ |
| 14 | [自增主键跳跃与性能](./indexing/14-auto-increment-gap) | ⭐⭐ | 5.7 & 8.0 |
| 15 | [索引合并 Index Merge 陷阱](./indexing/15-index-merge-pitfall) | ⭐⭐ | 5.7 & 8.0 |
| 16 | [索引跳跃扫描 Skip Scan](./indexing/16-skip-scan) | ⭐⭐ | 8.0+ |
| 17 | [游标分页替代深分页](./indexing/17-cursor-pagination) | ⭐⭐ | 5.7 & 8.0 |
| 18 | [全文索引 FULLTEXT 替代 LIKE](./indexing/18-fulltext-search) | ⭐⭐ | 5.7 & 8.0 |

## 二、查询改写（14 个）

| # | 案例 | 难度 | 版本 |
|---|------|:----:|:----:|
| 19 | [子查询改写为 JOIN](./query-rewrite/19-subquery-to-join) | ⭐⭐ | 5.7 & 8.0 |
| 20 | [COUNT(*) 慢查询优化](./query-rewrite/20-count-optimization) | ⭐⭐ | 5.7 & 8.0 |
| 21 | [GROUP BY filesort 优化](./query-rewrite/21-group-by-filesort) | ⭐⭐ | 5.7 & 8.0 |
| 22 | [大 IN 列表优化](./query-rewrite/22-large-in-list) | ⭐⭐ | 5.7 & 8.0 |
| 23 | [EXISTS vs IN 选择](./query-rewrite/23-exists-vs-in) | ⭐⭐ | 5.7 & 8.0 |
| 24 | [DISTINCT 优化](./query-rewrite/24-distinct-optimization) | ⭐⭐ | 5.7 & 8.0 |
| 25 | [NOT IN vs LEFT JOIN IS NULL](./query-rewrite/25-not-in-vs-left-join) | ⭐⭐ | 5.7 & 8.0 |
| 26 | [UNION vs UNION ALL](./query-rewrite/26-union-vs-union-all) | ⭐ | 5.7 & 8.0 |
| 27 | [ORDER BY LIMIT 无索引优化](./query-rewrite/27-orderby-limit-no-index) | ⭐⭐ | 5.7 & 8.0 |
| 28 | [HAVING 改 WHERE 提前过滤](./query-rewrite/28-having-to-where) | ⭐ | 5.7 & 8.0 |
| 29 | [LIMIT 1 优化 EXISTS 子查询](./query-rewrite/29-limit1-exists) | ⭐⭐ | 5.7 & 8.0 |
| 30 | [时区与 TIMESTAMP vs DATETIME](./query-rewrite/30-timestamp-vs-datetime) | ⭐⭐ | 5.7 & 8.0 |
| 31 | [时间格式使用错误与最佳实践](./query-rewrite/31-time-format-antipattern) | ⭐⭐ | 5.7 & 8.0 |
| 32 | [SQL 反模式与正确写法量化对比](./query-rewrite/32-sql-antipatterns) | ⭐⭐ | 5.7 & 8.0 |

## 三、JOIN 优化（9 个）

| # | 案例 | 难度 | 版本 |
|---|------|:----:|:----:|
| 33 | [JOIN 小表驱动大表](./join/33-small-drive-large) | ⭐⭐ | 5.7 & 8.0 |
| 34 | [被驱动表无索引的灾难](./join/34-driven-no-index) | ⭐⭐ | 5.7 & 8.0 |
| 35 | [Hash Join vs BNL](./join/35-hash-join-vs-bnl) | ⭐⭐⭐ | 5.7 & 8.0 |
| 36 | [多表 JOIN 顺序控制](./join/36-join-order) | ⭐⭐⭐ | 5.7 & 8.0 |
| 37 | [自连接查询优化](./join/37-self-join-optimization) | ⭐⭐ | 5.7 & 8.0 |
| 38 | [JOIN + GROUP BY 聚合优化](./join/38-join-group-by-optimization) | ⭐⭐⭐ | 5.7 & 8.0 |
| 39 | [派生表物化优化](./join/39-derived-table-materialization) | ⭐⭐ | 5.7 & 8.0 |
| 40 | [STRAIGHT_JOIN 强制驱动顺序](./join/40-straight-join) | ⭐⭐⭐ | 5.7 & 8.0 |
| 41 | [LEFT JOIN 改 INNER JOIN 释放优化器](./join/41-left-join-to-inner) | ⭐⭐ | 5.7 & 8.0 |

## 四、DDL 与大表（10 个）

| # | 案例 | 难度 | 版本 |
|---|------|:----:|:----:|
| 42 | [大表加索引 Online DDL](./ddl/42-online-ddl) | ⭐⭐⭐ | 5.7 & 8.0 |
| 43 | [TEXT/BLOB 字段性能陷阱](./ddl/43-text-blob-pitfall) | ⭐⭐ | 5.7 & 8.0 |
| 44 | [大表 DELETE 分批](./ddl/44-batch-delete) | ⭐⭐ | 5.7 & 8.0 |
| 45 | [分区表 RANGE 分区优化](./ddl/45-partition-range) | ⭐⭐⭐ | 5.7 & 8.0 |
| 46 | [大表批量 INSERT 优化](./ddl/46-batch-insert-optimization) | ⭐⭐ | 5.7 & 8.0 |
| 47 | [OPTIMIZE TABLE 碎片整理](./ddl/47-optimize-table-fragmentation) | ⭐⭐ | 5.7 & 8.0 |
| 48 | [大表加列默认值 INSTANT 秒级完成](./ddl/48-instant-add-column) | ⭐⭐ | 5.7 & 8.0 |
| 49 | [修改字段类型的锁行为差异](./ddl/49-modify-column-type) | ⭐⭐⭐ | 5.7 & 8.0 |
| 50 | [大字段垂直拆表](./ddl/50-vertical-split-text) | ⭐⭐ | 5.7 & 8.0 |
| 51 | [字段类型与长度选择最佳实践](./ddl/51-field-type-best-practice) | ⭐⭐ | 5.7 & 8.0 |

## 五、架构级优化（11 个）

| # | 案例 | 难度 | 版本 |
|---|------|:----:|:----:|
| 52 | [多条件动态筛选索引设计](./architecture/52-dynamic-filter) | ⭐⭐⭐ | 5.7 & 8.0 |
| 53 | [报表统计汇总表](./architecture/53-summary-table) | ⭐⭐ | 5.7 & 8.0 |
| 54 | [冷热数据分离](./architecture/54-hot-cold-separation) | ⭐⭐⭐ | 5.7 & 8.0 |
| 55 | [秒杀场景库存扣减](./architecture/55-flash-sale-stock) | ⭐⭐⭐ | 5.7 & 8.0 |
| 56 | [读写分离架构](./architecture/56-read-write-splitting) | ⭐⭐⭐ | 5.7 & 8.0 |
| 57 | [JSON 字段使用模式](./architecture/57-json-column-pattern) | ⭐⭐ | 8.0+ |
| 58 | [软删除设计模式](./architecture/58-soft-delete-pattern) | ⭐⭐ | 5.7 & 8.0 |
| 59 | [分库分表路由策略](./architecture/59-sharding-route) | ⭐⭐⭐ | 5.7 & 8.0 |
| 60 | [缓存穿透与布隆过滤器](./architecture/60-cache-penetration) | ⭐⭐⭐ | 5.7 & 8.0 |
| 61 | [自增主键耗尽与分布式 ID](./architecture/61-auto-inc-exhaustion) | ⭐⭐⭐ | 5.7 & 8.0 |
| 62 | [连接池与 max_connections 耗尽诊断](./architecture/62-connection-pool-exhaustion) | ⭐⭐ | 5.7 & 8.0 |

## 六、事务与锁（9 个）

| # | 案例 | 难度 | 版本 |
|---|------|:----:|:----:|
| 63 | [死锁排查与分析](./transaction/63-deadlock-analysis) | ⭐⭐⭐ | 5.7 & 8.0 |
| 64 | [间隙锁导致插入阻塞](./transaction/64-gap-lock-insert-block) | ⭐⭐⭐ | 5.7 & 8.0 |
| 65 | [SELECT FOR UPDATE 锁范围](./transaction/65-select-for-update-scope) | ⭐⭐ | 5.7 & 8.0 |
| 66 | [乐观锁与悲观锁对比](./transaction/66-optimistic-vs-pessimistic-lock) | ⭐⭐ | 5.7 & 8.0 |
| 67 | [幻读问题与解决](./transaction/67-phantom-read) | ⭐⭐⭐ | 5.7 & 8.0 |
| 68 | [死锁重试与超时处理](./transaction/68-deadlock-retry-timeout) | ⭐⭐ | 5.7 & 8.0 |
| 69 | [唯一索引并发插入冲突](./transaction/69-unique-index-concurrent-insert) | ⭐⭐ | 5.7 & 8.0 |
| 70 | [长事务危害](./transaction/70-long-transaction-harm) | ⭐⭐ | 5.7 & 8.0 |
| 71 | [RC vs RR 隔离级别锁行为差异](./transaction/71-rc-vs-rr-isolation) | ⭐⭐⭐ | 5.7 & 8.0 |

## 七、优化器与 8.0 新特性（9 个）

| # | 案例 | 难度 | 版本 |
|---|------|:----:|:----:|
| 72 | [降序索引消除 filesort](./optimizer/72-descending-index) | ⭐⭐ | 5.7 & 8.0 |
| 73 | [函数索引优化 DATE 函数查询](./optimizer/73-functional-index) | ⭐⭐ | 8.0+ |
| 74 | [直方图统计优化选错索引](./optimizer/74-histogram-statistics) | ⭐⭐⭐ | 8.0+ |
| 75 | [CTE 递归查询优化树形结构](./optimizer/75-cte-recursive) | ⭐⭐ | 8.0+ |
| 76 | [窗口函数替代相关子查询](./optimizer/76-window-function) | ⭐⭐ | 8.0+ |
| 77 | [优化器 Hint 实战](./optimizer/77-optimizer-hint) | ⭐⭐ | 5.7 & 8.0 |
| 78 | [派生条件下推优化](./optimizer/78-derived-condition-pushdown) | ⭐⭐⭐ | 5.7 & 8.0 |
| 79 | [大批量 UPDATE 分批优化](./optimizer/79-batch-update) | ⭐⭐ | 5.7 & 8.0 |
| 80 | [慢查询排查方法论](./optimizer/80-slow-query-diagnosis) | ⭐⭐⭐ | 5.7 & 8.0 |
## 八、TiDB 分布式优化（22 个）

| # | 案例 | 难度 | 版本 |
|---|------|:----:|:----:|
| 81 | [TiDB EXPLAIN 算子树解读](./tidb/81-tidb-explain-tree) | ⭐⭐ | TiDB |
| 82 | [协处理器下推优化](./tidb/82-coprocessor-pushdown) | ⭐⭐⭐ | TiDB |
| 83 | [AUTO_RANDOM 避免写热点](./tidb/83-auto-random) | ⭐⭐ | TiDB |
| 84 | [TiDB 统计信息管理](./tidb/84-tidb-statistics) | ⭐⭐⭐ | TiDB |
| 85 | [TiDB 事务模型对比](./tidb/85-tidb-transaction) | ⭐⭐⭐ | TiDB |
| 86 | [IndexLookUp 回表与覆盖索引](./tidb/86-index-lookup) | ⭐⭐ | TiDB |
| 87 | [TiFlash 列存与 MPP 分析加速](./tidb/87-tiflash-mpp) | ⭐⭐⭐ | TiDB |
| 88 | [TiDB GC 机制与长事务影响](./tidb/88-tidb-gc) | ⭐⭐⭐ | TiDB |
| 89 | [Follower Read 读写分离](./tidb/89-follower-read) | ⭐⭐ | TiDB |
| 90 | [TiDB 内存控制与 OOM 防护](./tidb/90-tidb-memory-oom) | ⭐⭐⭐ | TiDB |
| 91 | [TiDB Join 算法选择](./tidb/91-tidb-join-algorithms) | ⭐⭐⭐ | TiDB |
| 92 | [TiDB 在线 DDL 机制](./tidb/92-tidb-online-ddl) | ⭐⭐ | TiDB |
| 93 | [TiDB Plan Cache 执行计划缓存](./tidb/93-tidb-plan-cache) | ⭐⭐ | TiDB |
| 94 | [TiDB Stale Read 历史读优化](./tidb/94-tidb-stale-read) | ⭐⭐ | TiDB |
| 95 | [Region 热点调度与 Split 策略](./tidb/95-region-hotspot) | ⭐⭐⭐ | TiDB |
| 96 | [SQL Binding 执行计划锁定 (SPM)](./tidb/96-sql-binding) | ⭐⭐⭐ | TiDB |
| 97 | [TiDB 分区表优化](./tidb/97-tidb-partition) | ⭐⭐ | TiDB |
| 98 | [TiDB Dashboard 诊断实战](./tidb/98-tidb-dashboard) | ⭐⭐ | TiDB |
| 99 | [TiDB 锁机制深度解析](./tidb/99-tidb-lock-deep) | ⭐⭐⭐ | TiDB |
| 100 | [分布式 Sequence 自增方案](./tidb/100-tidb-sequence) | ⭐⭐ | TiDB |
| 101 | [TiDB CTE 与临时表优化](./tidb/101-tidb-cte) | ⭐⭐ | TiDB |
| 102 | [TiDB Cost Model 与优化器 Hint 进阶](./tidb/102-tidb-cost-hint) | ⭐⭐⭐ | TiDB |

---

::: tip 难度说明
- ⭐ 入门：理解索引基本原理即可
- ⭐⭐ 进阶：需要理解 EXPLAIN 输出和优化器行为
- ⭐⭐⭐ 高级：涉及架构设计或版本特性差异
:::
