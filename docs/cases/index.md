# 案例总览

共 **116 个精选案例**，覆盖 MySQL + TiDB 优化的八大核心场景。每个案例都带真实数据，可一键复现。

## 一、索引设计与失效（20 个）

| # | 案例 | 难度 | 版本 |
|---|------|:----:|:----:|
| 1 | [深度分页 LIMIT 大偏移](./indexing/1-deep-pagination) | ⭐⭐ | 5.7 & 8.0 |
| 2 | [联合索引最左前缀失效](./indexing/2-leftmost-prefix) | ⭐ | 5.7 & 8.0 |
| 3 | [隐式类型转换致索引失效](./indexing/3-implicit-type-conversion) | ⭐⭐ | 5.7 & 8.0 |
| 4 | [函数操作致索引失效](./indexing/4-function-on-index) | ⭐⭐ | 5.7 & 8.0 |
| 5 | [LIKE 前导通配符致索引失效](./indexing/5-like-leading-wildcard) | ⭐ | 5.7 & 8.0 |
| 6 | [OR 条件与索引合并](./indexing/6-or-condition) | ⭐⭐ | 5.7 & 8.0 |
| 7 | [范围查询后列索引失效](./indexing/7-range-after-index) | ⭐⭐ | 5.7 & 8.0 |
| 8 | [覆盖索引避免回表](./indexing/8-covering-index) | ⭐⭐ | 5.7 & 8.0 |
| 9 | [索引下推 ICP（Index Condition Pushdown）](./indexing/9-index-condition-pushdown) | ⭐⭐⭐ | 5.6 & 5.7 & 8.0 |
| 10 | [冗余索引清理](./indexing/10-redundant-index-cleanup) | ⭐⭐ | 5.7 & 8.0 |
| 11 | [前缀索引优化长字符串](./indexing/11-prefix-index) | ⭐⭐ | 5.7 & 8.0 |
| 12 | [索引选择性评估](./indexing/12-index-selectivity) | ⭐⭐ | 5.7 & 8.0 |
| 13 | [不可见索引 Invisible Index](./indexing/13-invisible-index) | ⭐⭐ | 8.0+ |
| 14 | [自增主键跳跃与性能](./indexing/14-auto-increment-gap) | ⭐⭐ | 5.7 & 8.0 |
| 15 | [索引合并 Index Merge 陷阱](./indexing/15-index-merge-pitfall) | ⭐⭐ | 5.7 & 8.0 |
| 16 | [索引跳跃扫描 Skip Scan](./indexing/16-skip-scan) | ⭐⭐ | 8.0+ |
| 17 | [游标分页替代深分页](./indexing/17-cursor-pagination) | ⭐⭐ | 5.7 & 8.0 |
| 18 | [全文索引 FULLTEXT 替代 LIKE](./indexing/18-fulltext-search) | ⭐⭐ | 5.7 & 8.0 |
| 19 | [自适应哈希索引 AHI 调优](./indexing/19-adaptive-hash-index) | ⭐⭐⭐ | 5.7 & 8.0 |
| 20 | [Change Buffer 二级索引写入加速](./indexing/20-change-buffer) | ⭐⭐⭐ | 5.7 & 8.0 |

## 二、查询改写（15 个）

| # | 案例 | 难度 | 版本 |
|---|------|:----:|:----:|
| 21 | [子查询改写为 JOIN](./query-rewrite/21-subquery-to-join) | ⭐⭐ | 5.7 & 8.0 |
| 22 | [COUNT(*) 慢查询优化](./query-rewrite/22-count-optimization) | ⭐⭐ | 5.7 & 8.0 |
| 23 | [GROUP BY filesort 优化](./query-rewrite/23-group-by-filesort) | ⭐⭐ | 5.7 & 8.0 |
| 24 | [大 IN 列表优化](./query-rewrite/24-large-in-list) | ⭐⭐ | 5.7 & 8.0 |
| 25 | [EXISTS vs IN 选择](./query-rewrite/25-exists-vs-in) | ⭐⭐ | 5.7 & 8.0 |
| 26 | [DISTINCT 优化](./query-rewrite/26-distinct-optimization) | ⭐⭐ | 5.7 & 8.0 |
| 27 | [NOT IN vs LEFT JOIN IS NULL](./query-rewrite/27-not-in-vs-left-join) | ⭐⭐ | 5.7 & 8.0 |
| 28 | [UNION vs UNION ALL](./query-rewrite/28-union-vs-union-all) | ⭐ | 5.7 & 8.0 |
| 29 | [ORDER BY LIMIT 无索引优化](./query-rewrite/29-orderby-limit-no-index) | ⭐⭐ | 5.7 & 8.0 |
| 30 | [HAVING 改 WHERE 提前过滤](./query-rewrite/30-having-to-where) | ⭐ | 5.7 & 8.0 |
| 31 | [LIMIT 1 优化 EXISTS 子查询](./query-rewrite/31-limit1-exists) | ⭐⭐ | 5.7 & 8.0 |
| 32 | [时区与 TIMESTAMP vs DATETIME](./query-rewrite/32-timestamp-vs-datetime) | ⭐⭐ | 5.7 & 8.0 |
| 33 | [时间格式使用错误与最佳实践](./query-rewrite/33-time-format-antipattern) | ⭐⭐ | 5.7 & 8.0 |
| 34 | [SQL 反模式与正确写法量化对比](./query-rewrite/34-sql-antipatterns) | ⭐⭐ | 5.7 & 8.0 |
| 35 | [EXPLAIN FORMAT=JSON 详细成本树解读](./query-rewrite/35-explain-format-json) | ⭐⭐⭐ | 5.7 & 8.0 |

## 三、JOIN 优化（9 个）

| # | 案例 | 难度 | 版本 |
|---|------|:----:|:----:|
| 36 | [JOIN 小表驱动大表](./join/36-small-drive-large) | ⭐⭐ | 5.7 & 8.0 |
| 37 | [被驱动表无索引的灾难](./join/37-driven-no-index) | ⭐⭐ | 5.7 & 8.0 |
| 38 | [Hash Join vs BNL](./join/38-hash-join-vs-bnl) | ⭐⭐⭐ | 5.7 & 8.0 |
| 39 | [多表 JOIN 顺序控制](./join/39-join-order) | ⭐⭐⭐ | 5.7 & 8.0 |
| 40 | [自连接查询优化](./join/40-self-join-optimization) | ⭐⭐ | 5.7 & 8.0 |
| 41 | [JOIN + GROUP BY 聚合优化](./join/41-join-group-by-optimization) | ⭐⭐⭐ | 5.7 & 8.0 |
| 42 | [派生表物化优化](./join/42-derived-table-materialization) | ⭐⭐ | 5.7 & 8.0 |
| 43 | [STRAIGHT_JOIN 强制驱动顺序](./join/43-straight-join) | ⭐⭐⭐ | 5.7 & 8.0 |
| 44 | [LEFT JOIN 改 INNER JOIN 释放优化器](./join/44-left-join-to-inner) | ⭐⭐ | 5.7 & 8.0 |

## 四、DDL 与大表（14 个）

| # | 案例 | 难度 | 版本 |
|---|------|:----:|:----:|
| 45 | [大表加索引 Online DDL](./ddl/45-online-ddl) | ⭐⭐⭐ | 5.7 & 8.0 |
| 46 | [大表增删列 INSTANT 操作全解](./ddl/46-large-table-add-drop-column) | ⭐⭐⭐ | 5.7 & 8.0 |
| 47 | [TEXT/BLOB 字段性能陷阱](./ddl/47-text-blob-pitfall) | ⭐⭐ | 5.7 & 8.0 |
| 48 | [大表 DELETE 分批](./ddl/48-batch-delete) | ⭐⭐ | 5.7 & 8.0 |
| 49 | [分区表 RANGE 分区优化](./ddl/49-partition-range) | ⭐⭐⭐ | 5.7 & 8.0 |
| 50 | [大表批量 INSERT 优化](./ddl/50-batch-insert-optimization) | ⭐⭐ | 5.7 & 8.0 |
| 51 | [OPTIMIZE TABLE 碎片整理](./ddl/51-optimize-table-fragmentation) | ⭐⭐ | 5.7 & 8.0 |
| 52 | [大表加列默认值 INSTANT 秒级完成](./ddl/52-instant-add-column) | ⭐⭐ | 5.7 & 8.0 |
| 53 | [修改字段类型的锁行为差异](./ddl/53-modify-column-type) | ⭐⭐⭐ | 5.7 & 8.0 |
| 54 | [大字段垂直拆表](./ddl/54-vertical-split-text) | ⭐⭐ | 5.7 & 8.0 |
| 55 | [字段类型与长度选择最佳实践](./ddl/55-field-type-best-practice) | ⭐⭐ | 5.7 & 8.0 |
| 56 | [数据建模方法论与建表清单](./ddl/56-data-modeling-guide) | ⭐⭐⭐ | 5.7 & 8.0 |
| 57 | [设计决策背后的理论依据](./ddl/57-design-decisions-theory) | ⭐⭐⭐ | 5.7 & 8.0 |
| 58 | [SELECT INTO OUTFILE 大数据导出与安全](./ddl/58-select-into-outfile) | ⭐⭐ | 5.7 & 8.0 |

## 五、架构级优化（15 个）

| # | 案例 | 难度 | 版本 |
|---|------|:----:|:----:|
| 59 | [多条件动态筛选索引设计](./architecture/59-dynamic-filter) | ⭐⭐⭐ | 5.7 & 8.0 |
| 60 | [报表统计汇总表](./architecture/60-summary-table) | ⭐⭐ | 5.7 & 8.0 |
| 61 | [冷热数据分离](./architecture/61-hot-cold-separation) | ⭐⭐⭐ | 5.7 & 8.0 |
| 62 | [秒杀场景库存扣减](./architecture/62-flash-sale-stock) | ⭐⭐⭐ | 5.7 & 8.0 |
| 63 | [读写分离架构](./architecture/63-read-write-splitting) | ⭐⭐⭐ | 5.7 & 8.0 |
| 64 | [JSON 字段使用模式](./architecture/64-json-column-pattern) | ⭐⭐ | 8.0+ |
| 65 | [软删除设计模式](./architecture/65-soft-delete-pattern) | ⭐⭐ | 5.7 & 8.0 |
| 66 | [分库分表路由策略](./architecture/66-sharding-route) | ⭐⭐⭐ | 5.7 & 8.0 |
| 67 | [缓存穿透与布隆过滤器](./architecture/67-cache-penetration) | ⭐⭐⭐ | 5.7 & 8.0 |
| 68 | [自增主键耗尽与分布式 ID](./architecture/68-auto-inc-exhaustion) | ⭐⭐⭐ | 5.7 & 8.0 |
| 69 | [自增序列 8 个坑全景手册](./architecture/69-auto-increment-pitfalls) | ⭐⭐⭐ | 5.7 & 8.0 |
| 70 | [连接池与 max_connections 耗尽诊断](./architecture/70-connection-pool-exhaustion) | ⭐⭐ | 5.7 & 8.0 |
| 71 | [HikariCP/Druid 连接池参数调优](./architecture/71-connection-pool-tuning) | ⭐⭐⭐ | 5.7 & 8.0 |
| 72 | [InnoDB Buffer Pool 调优](./architecture/72-innodb-buffer-pool) | ⭐⭐⭐ | 5.7 & 8.0 |
| 73 | [MySQL 重启后 Buffer Pool 冷启动预热](./architecture/73-buffer-pool-warmup) | ⭐⭐⭐ | 5.7 & 8.0 |

## 六、事务与锁（11 个）

| # | 案例 | 难度 | 版本 |
|---|------|:----:|:----:|
| 74 | [死锁排查与分析](./transaction/74-deadlock-analysis) | ⭐⭐⭐ | 5.7 & 8.0 |
| 75 | [间隙锁导致插入阻塞](./transaction/75-gap-lock-insert-block) | ⭐⭐⭐ | 5.7 & 8.0 |
| 76 | [SELECT FOR UPDATE 锁范围](./transaction/76-select-for-update-scope) | ⭐⭐ | 5.7 & 8.0 |
| 77 | [乐观锁与悲观锁对比](./transaction/77-optimistic-vs-pessimistic-lock) | ⭐⭐ | 5.7 & 8.0 |
| 78 | [幻读问题与解决](./transaction/78-phantom-read) | ⭐⭐⭐ | 5.7 & 8.0 |
| 79 | [死锁重试与超时处理](./transaction/79-deadlock-retry-timeout) | ⭐⭐ | 5.7 & 8.0 |
| 80 | [唯一索引并发插入冲突](./transaction/80-unique-index-concurrent-insert) | ⭐⭐ | 5.7 & 8.0 |
| 81 | [长事务危害](./transaction/81-long-transaction-harm) | ⭐⭐ | 5.7 & 8.0 |
| 82 | [RC vs RR 隔离级别锁行为差异](./transaction/82-rc-vs-rr-isolation) | ⭐⭐⭐ | 5.7 & 8.0 |
| 83 | [undo 表空间膨胀与 Purge 调优](./transaction/83-undo-tablespace) | ⭐⭐⭐ | 5.7 & 8.0 |
| 84 | [通用慢查询排查与锁等待定位](./transaction/84-slow-query-diagnosis) | ⭐⭐⭐ | 5.7 & 8.0 |

## 七、优化器与 8.0 新特性（10 个）

| # | 案例 | 难度 | 版本 |
|---|------|:----:|:----:|
| 85 | [降序索引消除 filesort](./optimizer/85-descending-index) | ⭐⭐ | 5.7 & 8.0 |
| 86 | [函数索引优化 DATE 函数查询](./optimizer/86-functional-index) | ⭐⭐ | 8.0+ |
| 87 | [直方图统计优化选错索引](./optimizer/87-histogram-statistics) | ⭐⭐⭐ | 8.0+ |
| 88 | [CTE 递归查询优化树形结构](./optimizer/88-cte-recursive) | ⭐⭐ | 8.0+ |
| 89 | [窗口函数替代相关子查询](./optimizer/89-window-function) | ⭐⭐ | 8.0+ |
| 90 | [优化器 Hint 实战](./optimizer/90-optimizer-hint) | ⭐⭐ | 5.7 & 8.0 |
| 91 | [派生条件下推优化](./optimizer/91-derived-condition-pushdown) | ⭐⭐⭐ | 5.7 & 8.0 |
| 92 | [大批量 UPDATE 分批优化](./optimizer/92-batch-update) | ⭐⭐ | 5.7 & 8.0 |
| 93 | [慢查询排查方法论](./optimizer/93-slow-query-diagnosis) | ⭐⭐⭐ | 5.7 & 8.0 |
| 94 | [MySQL 8.0 并行查询 (Parallel Execution)](./optimizer/94-parallel-execution) | ⭐⭐⭐ | 8.0.27+ |
## 八、TiDB 分布式优化（22 个）

| # | 案例 | 难度 | 版本 |
|---|------|:----:|:----:|
| 95 | [TiDB EXPLAIN 算子树解读](./tidb/95-tidb-explain-tree) | ⭐⭐ | TiDB |
| 96 | [协处理器下推优化](./tidb/96-coprocessor-pushdown) | ⭐⭐⭐ | TiDB |
| 97 | [AUTO_RANDOM 避免写热点](./tidb/97-auto-random) | ⭐⭐ | TiDB |
| 98 | [TiDB 统计信息管理](./tidb/98-tidb-statistics) | ⭐⭐⭐ | TiDB |
| 99 | [TiDB 事务模型对比](./tidb/99-tidb-transaction) | ⭐⭐⭐ | TiDB |
| 100 | [IndexLookUp 回表与覆盖索引](./tidb/100-index-lookup) | ⭐⭐ | TiDB |
| 101 | [TiFlash 列存与 MPP 分析加速](./tidb/101-tiflash-mpp) | ⭐⭐⭐ | TiDB |
| 102 | [TiDB GC 机制与长事务影响](./tidb/102-tidb-gc) | ⭐⭐⭐ | TiDB |
| 103 | [Follower Read 读写分离](./tidb/103-follower-read) | ⭐⭐ | TiDB |
| 104 | [TiDB 内存控制与 OOM 防护](./tidb/104-tidb-memory-oom) | ⭐⭐⭐ | TiDB |
| 105 | [TiDB Join 算法选择](./tidb/105-tidb-join-algorithms) | ⭐⭐⭐ | TiDB |
| 106 | [TiDB 在线 DDL 机制](./tidb/106-tidb-online-ddl) | ⭐⭐ | TiDB |
| 107 | [TiDB Plan Cache 执行计划缓存](./tidb/107-tidb-plan-cache) | ⭐⭐ | TiDB |
| 108 | [TiDB Stale Read 历史读优化](./tidb/108-tidb-stale-read) | ⭐⭐ | TiDB |
| 109 | [Region 热点调度与 Split 策略](./tidb/109-region-hotspot) | ⭐⭐⭐ | TiDB |
| 110 | [SQL Binding 执行计划锁定 (SPM)](./tidb/110-sql-binding) | ⭐⭐⭐ | TiDB |
| 111 | [TiDB 分区表优化](./tidb/111-tidb-partition) | ⭐⭐ | TiDB |
| 112 | [TiDB Dashboard 诊断实战](./tidb/112-tidb-dashboard) | ⭐⭐ | TiDB |
| 113 | [TiDB 锁机制深度解析](./tidb/113-tidb-lock-deep) | ⭐⭐⭐ | TiDB |
| 114 | [分布式 Sequence 自增方案](./tidb/114-tidb-sequence) | ⭐⭐ | TiDB |
| 115 | [TiDB CTE 与临时表优化](./tidb/115-tidb-cte) | ⭐⭐ | TiDB |
| 116 | [TiDB Cost Model 与优化器 Hint 进阶](./tidb/116-tidb-cost-hint) | ⭐⭐⭐ | TiDB |

---

::: tip 难度说明
- ⭐ 入门：理解索引基本原理即可
- ⭐⭐ 进阶：需要理解 EXPLAIN 输出和优化器行为
- ⭐⭐⭐ 高级：涉及架构设计或版本特性差异
:::
