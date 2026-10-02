# SQL Lab

> 🐳 一套**能跑、能量化对比**的 MySQL + TiDB 优化实战案例集  
> 每个案例都带真实数据，Docker 一键复现，bad/good EXPLAIN 量化对比

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![MySQL](https://img.shields.io/badge/MySQL-5.7%20%7C%208.0-blue.svg)](https://www.mysql.com/)
[![TiDB](https://img.shields.io/badge/TiDB-v7.5.1-purple.svg)](https://pingcap.com/)
[![CI](https://github.com/slowleelab/sql-lab/actions/workflows/validate-sql.yml/badge.svg)](https://github.com/slowleelab/sql-lab/actions)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](CONTRIBUTING.md)
[![Cases](https://img.shields.io/badge/cases-116-orange.svg)](docs/cases/)

📖 **在线文档**：[https://slowleelab.github.io/sql-lab/](https://slowleelab.github.io/sql-lab/)  
📥 **PDF 下载**：[sql-lab-cases.pdf](https://slowleelab.github.io/sql-lab/sql-lab-cases.pdf) (~52 MB, 820+ 页, 118 书签)  
🤖 **AI 对话**：接入 DeepWiki，可直接与仓库对话提问

> 如果这个项目对你有帮助，欢迎 ⭐ Star 支持！你的 Star 是持续更新的动力。

---

## ✨ 为什么用这个项目

网上不缺 SQL 优化文章，但大多**只讲不练**——贴一段 SQL 说"这样慢，那样快"，你却无法验证。

本项目不同：

| 特性 | 普通文章 | SQL Lab |
|------|---------|-------------|
| 能否复现 | ❌ 只能看 | ✅ Docker 一键跑 |
| 数据量 | ❌ 假数据/无数据 | ✅ 百万级真实数据 |
| 效果验证 | ❌ 口头说快 | ✅ EXPLAIN 量化对比 |
| 版本覆盖 | ❌ 不区分版本 | ✅ 5.7 + 8.0 + TiDB |
| 场景贴近 | ❌ 教科书式 | ✅ 生产场景命名 |

## 🚀 快速开始

```bash
# 1. 克隆
git clone https://github.com/slowleelab/sql-lab.git
cd sql-lab

# 2. 启动 MySQL（同时起 5.7 和 8.0）
docker compose up -d

# 3. 运行第一个案例
./scripts/run-case.sh 1-deep-pagination
```

你会看到类似这样的输出：

```
━━━ bad.sql (优化前) ━━━
type: ALL    rows: 980,000    Extra: Using filesort
耗时: 1230 ms

━━━ good.sql (优化后) ━━━
type: ref    rows: 12    Extra: Using index
耗时: 2 ms

🚀 扫描行数下降 99.99%，耗时下降 99.84%
```

## 📚 案例总览

共 **116 个精选案例**，覆盖 MySQL + TiDB 优化的八大核心场景：

### 一、索引设计与失效（20 个）
| # | 案例 | 难度 | 版本 |
|---|------|------|------|
| 1 | [深度分页 LIMIT 大偏移](docs/cases/indexing/1-deep-pagination.md) | ⭐⭐ | 5.7 & 8.0 |
| 2 | [联合索引最左前缀失效](docs/cases/indexing/2-leftmost-prefix.md) | ⭐ | 5.7 & 8.0 |
| 3 | [隐式类型转换致索引失效](docs/cases/indexing/3-implicit-type-conversion.md) | ⭐⭐ | 5.7 & 8.0 |
| 4 | [函数操作致索引失效](docs/cases/indexing/4-function-on-index.md) | ⭐⭐ | 5.7 & 8.0 |
| 5 | [LIKE 前导通配符致索引失效](docs/cases/indexing/5-like-leading-wildcard.md) | ⭐ | 5.7 & 8.0 |
| 6 | [OR 条件与索引合并](docs/cases/indexing/6-or-condition.md) | ⭐⭐ | 5.7 & 8.0 |
| 7 | [范围查询后列索引失效](docs/cases/indexing/7-range-after-index.md) | ⭐⭐ | 5.7 & 8.0 |
| 8 | [覆盖索引避免回表](docs/cases/indexing/8-covering-index.md) | ⭐⭐ | 5.7 & 8.0 |
| 9 | [索引下推 ICP（Index Condition Pushdown）](docs/cases/indexing/9-index-condition-pushdown.md) | ⭐⭐⭐ | 5.6 & 5.7 & 8.0 |
| 10 | [冗余索引清理](docs/cases/indexing/10-redundant-index-cleanup.md) | ⭐⭐ | 5.7 & 8.0 |
| 11 | [前缀索引优化长字符串](docs/cases/indexing/11-prefix-index.md) | ⭐⭐ | 5.7 & 8.0 |
| 12 | [索引选择性评估](docs/cases/indexing/12-index-selectivity.md) | ⭐⭐ | 5.7 & 8.0 |
| 13 | [不可见索引 Invisible Index](docs/cases/indexing/13-invisible-index.md) | ⭐⭐ | 8.0+ |
| 14 | [自增主键跳跃与性能](docs/cases/indexing/14-auto-increment-gap.md) | ⭐⭐ | 5.7 & 8.0 |
| 15 | [索引合并 Index Merge 陷阱](docs/cases/indexing/15-index-merge-pitfall.md) | ⭐⭐ | 5.7 & 8.0 |
| 16 | [索引跳跃扫描 Skip Scan](docs/cases/indexing/16-skip-scan.md) | ⭐⭐ | 8.0+ |
| 17 | [游标分页替代深分页](docs/cases/indexing/17-cursor-pagination.md) | ⭐⭐ | 5.7 & 8.0 |
| 18 | [全文索引 FULLTEXT 替代 LIKE](docs/cases/indexing/18-fulltext-search.md) | ⭐⭐ | 5.7 & 8.0 |
| 19 | [自适应哈希索引 AHI 调优](docs/cases/indexing/19-adaptive-hash-index.md) | ⭐⭐⭐ | 5.7 & 8.0 |
| 20 | [Change Buffer 二级索引写入加速](docs/cases/indexing/20-change-buffer.md) | ⭐⭐⭐ | 5.7 & 8.0 |

### 二、查询改写（15 个）
| # | 案例 | 难度 | 版本 |
|---|------|------|------|
| 21 | [子查询改写为 JOIN](docs/cases/query-rewrite/21-subquery-to-join.md) | ⭐⭐ | 5.7 & 8.0 |
| 22 | [COUNT(*) 慢查询优化](docs/cases/query-rewrite/22-count-optimization.md) | ⭐⭐ | 5.7 & 8.0 |
| 23 | [GROUP BY filesort 优化](docs/cases/query-rewrite/23-group-by-filesort.md) | ⭐⭐ | 5.7 & 8.0 |
| 24 | [大 IN 列表优化](docs/cases/query-rewrite/24-large-in-list.md) | ⭐⭐ | 5.7 & 8.0 |
| 25 | [EXISTS vs IN 选择](docs/cases/query-rewrite/25-exists-vs-in.md) | ⭐⭐ | 5.7 & 8.0 |
| 26 | [DISTINCT 优化](docs/cases/query-rewrite/26-distinct-optimization.md) | ⭐⭐ | 5.7 & 8.0 |
| 27 | [NOT IN vs LEFT JOIN IS NULL](docs/cases/query-rewrite/27-not-in-vs-left-join.md) | ⭐⭐ | 5.7 & 8.0 |
| 28 | [UNION vs UNION ALL](docs/cases/query-rewrite/28-union-vs-union-all.md) | ⭐ | 5.7 & 8.0 |
| 29 | [ORDER BY LIMIT 无索引优化](docs/cases/query-rewrite/29-orderby-limit-no-index.md) | ⭐⭐ | 5.7 & 8.0 |
| 30 | [HAVING 改 WHERE 提前过滤](docs/cases/query-rewrite/30-having-to-where.md) | ⭐ | 5.7 & 8.0 |
| 31 | [LIMIT 1 优化 EXISTS 子查询](docs/cases/query-rewrite/31-limit1-exists.md) | ⭐⭐ | 5.7 & 8.0 |
| 32 | [时区与 TIMESTAMP vs DATETIME](docs/cases/query-rewrite/32-timestamp-vs-datetime.md) | ⭐⭐ | 5.7 & 8.0 |
| 33 | [时间格式使用错误与最佳实践](docs/cases/query-rewrite/33-time-format-antipattern.md) | ⭐⭐ | 5.7 & 8.0 |
| 34 | [SQL 反模式与正确写法量化对比](docs/cases/query-rewrite/34-sql-antipatterns.md) | ⭐⭐ | 5.7 & 8.0 |
| 35 | [EXPLAIN FORMAT=JSON 详细成本树解读](docs/cases/query-rewrite/35-explain-format-json.md) | ⭐⭐⭐ | 5.7 & 8.0 |

### 三、JOIN 优化（9 个）
| # | 案例 | 难度 | 版本 |
|---|------|------|------|
| 36 | [JOIN 小表驱动大表](docs/cases/join/36-small-drive-large.md) | ⭐⭐ | 5.7 & 8.0 |
| 37 | [被驱动表无索引的灾难](docs/cases/join/37-driven-no-index.md) | ⭐⭐ | 5.7 & 8.0 |
| 38 | [Hash Join vs BNL](docs/cases/join/38-hash-join-vs-bnl.md) | ⭐⭐⭐ | 5.7 & 8.0 |
| 39 | [多表 JOIN 顺序控制](docs/cases/join/39-join-order.md) | ⭐⭐⭐ | 5.7 & 8.0 |
| 40 | [自连接查询优化](docs/cases/join/40-self-join-optimization.md) | ⭐⭐ | 5.7 & 8.0 |
| 41 | [JOIN + GROUP BY 聚合优化](docs/cases/join/41-join-group-by-optimization.md) | ⭐⭐⭐ | 5.7 & 8.0 |
| 42 | [派生表物化优化](docs/cases/join/42-derived-table-materialization.md) | ⭐⭐ | 5.7 & 8.0 |
| 43 | [STRAIGHT_JOIN 强制驱动顺序](docs/cases/join/43-straight-join.md) | ⭐⭐⭐ | 5.7 & 8.0 |
| 44 | [LEFT JOIN 改 INNER JOIN 释放优化器](docs/cases/join/44-left-join-to-inner.md) | ⭐⭐ | 5.7 & 8.0 |

### 四、DDL 与大表（14 个）
| # | 案例 | 难度 | 版本 |
|---|------|------|------|
| 45 | [大表加索引 Online DDL](docs/cases/ddl/45-online-ddl.md) | ⭐⭐⭐ | 5.7 & 8.0 |
| 46 | [大表增删列 INSTANT 操作全解](docs/cases/ddl/46-large-table-add-drop-column.md) | ⭐⭐⭐ | 5.7 & 8.0 |
| 47 | [TEXT/BLOB 字段性能陷阱](docs/cases/ddl/47-text-blob-pitfall.md) | ⭐⭐ | 5.7 & 8.0 |
| 48 | [大表 DELETE 分批](docs/cases/ddl/48-batch-delete.md) | ⭐⭐ | 5.7 & 8.0 |
| 49 | [分区表 RANGE 分区优化](docs/cases/ddl/49-partition-range.md) | ⭐⭐⭐ | 5.7 & 8.0 |
| 50 | [大表批量 INSERT 优化](docs/cases/ddl/50-batch-insert-optimization.md) | ⭐⭐ | 5.7 & 8.0 |
| 51 | [OPTIMIZE TABLE 碎片整理](docs/cases/ddl/51-optimize-table-fragmentation.md) | ⭐⭐ | 5.7 & 8.0 |
| 52 | [大表加列默认值 INSTANT 秒级完成](docs/cases/ddl/52-instant-add-column.md) | ⭐⭐ | 5.7 & 8.0 |
| 53 | [修改字段类型的锁行为差异](docs/cases/ddl/53-modify-column-type.md) | ⭐⭐⭐ | 5.7 & 8.0 |
| 54 | [大字段垂直拆表](docs/cases/ddl/54-vertical-split-text.md) | ⭐⭐ | 5.7 & 8.0 |
| 55 | [字段类型与长度选择最佳实践](docs/cases/ddl/55-field-type-best-practice.md) | ⭐⭐ | 5.7 & 8.0 |
| 56 | [数据建模方法论与建表清单](docs/cases/ddl/56-data-modeling-guide.md) | ⭐⭐⭐ | 5.7 & 8.0 |
| 57 | [设计决策背后的理论依据](docs/cases/ddl/57-design-decisions-theory.md) | ⭐⭐⭐ | 5.7 & 8.0 |
| 58 | [SELECT INTO OUTFILE 大数据导出与安全](docs/cases/ddl/58-select-into-outfile.md) | ⭐⭐ | 5.7 & 8.0 |

### 五、架构级优化（15 个）
| # | 案例 | 难度 | 版本 |
|---|------|------|------|
| 59 | [多条件动态筛选索引设计](docs/cases/architecture/59-dynamic-filter.md) | ⭐⭐⭐ | 5.7 & 8.0 |
| 60 | [报表统计汇总表](docs/cases/architecture/60-summary-table.md) | ⭐⭐ | 5.7 & 8.0 |
| 61 | [冷热数据分离](docs/cases/architecture/61-hot-cold-separation.md) | ⭐⭐⭐ | 5.7 & 8.0 |
| 62 | [秒杀场景库存扣减](docs/cases/architecture/62-flash-sale-stock.md) | ⭐⭐⭐ | 5.7 & 8.0 |
| 63 | [读写分离架构](docs/cases/architecture/63-read-write-splitting.md) | ⭐⭐⭐ | 5.7 & 8.0 |
| 64 | [JSON 字段使用模式](docs/cases/architecture/64-json-column-pattern.md) | ⭐⭐ | 8.0+ |
| 65 | [软删除设计模式](docs/cases/architecture/65-soft-delete-pattern.md) | ⭐⭐ | 5.7 & 8.0 |
| 66 | [分库分表路由策略](docs/cases/architecture/66-sharding-route.md) | ⭐⭐⭐ | 5.7 & 8.0 |
| 67 | [缓存穿透与布隆过滤器](docs/cases/architecture/67-cache-penetration.md) | ⭐⭐⭐ | 5.7 & 8.0 |
| 68 | [自增主键耗尽与分布式 ID](docs/cases/architecture/68-auto-inc-exhaustion.md) | ⭐⭐⭐ | 5.7 & 8.0 |
| 69 | [自增序列 8 个坑全景手册](docs/cases/architecture/69-auto-increment-pitfalls.md) | ⭐⭐⭐ | 5.7 & 8.0 |
| 70 | [连接池与 max_connections 耗尽诊断](docs/cases/architecture/70-connection-pool-exhaustion.md) | ⭐⭐ | 5.7 & 8.0 |
| 71 | [HikariCP/Druid 连接池参数调优](docs/cases/architecture/71-connection-pool-tuning.md) | ⭐⭐⭐ | 5.7 & 8.0 |
| 72 | [InnoDB Buffer Pool 调优](docs/cases/architecture/72-innodb-buffer-pool.md) | ⭐⭐⭐ | 5.7 & 8.0 |
| 73 | [MySQL 重启后 Buffer Pool 冷启动预热](docs/cases/architecture/73-buffer-pool-warmup.md) | ⭐⭐⭐ | 5.7 & 8.0 |

### 六、事务与锁（11 个）
| # | 案例 | 难度 | 版本 |
|---|------|------|------|
| 74 | [死锁排查与分析](docs/cases/transaction/74-deadlock-analysis.md) | ⭐⭐⭐ | 5.7 & 8.0 |
| 75 | [间隙锁导致插入阻塞](docs/cases/transaction/75-gap-lock-insert-block.md) | ⭐⭐⭐ | 5.7 & 8.0 |
| 76 | [SELECT FOR UPDATE 锁范围](docs/cases/transaction/76-select-for-update-scope.md) | ⭐⭐ | 5.7 & 8.0 |
| 77 | [乐观锁与悲观锁对比](docs/cases/transaction/77-optimistic-vs-pessimistic-lock.md) | ⭐⭐ | 5.7 & 8.0 |
| 78 | [幻读问题与解决](docs/cases/transaction/78-phantom-read.md) | ⭐⭐⭐ | 5.7 & 8.0 |
| 79 | [死锁重试与超时处理](docs/cases/transaction/79-deadlock-retry-timeout.md) | ⭐⭐ | 5.7 & 8.0 |
| 80 | [唯一索引并发插入冲突](docs/cases/transaction/80-unique-index-concurrent-insert.md) | ⭐⭐ | 5.7 & 8.0 |
| 81 | [长事务危害](docs/cases/transaction/81-long-transaction-harm.md) | ⭐⭐ | 5.7 & 8.0 |
| 82 | [RC vs RR 隔离级别锁行为差异](docs/cases/transaction/82-rc-vs-rr-isolation.md) | ⭐⭐⭐ | 5.7 & 8.0 |
| 83 | [undo 表空间膨胀与 Purge 调优](docs/cases/transaction/83-undo-tablespace.md) | ⭐⭐⭐ | 5.7 & 8.0 |
| 84 | [通用慢查询排查与锁等待定位](docs/cases/transaction/84-slow-query-diagnosis.md) | ⭐⭐⭐ | 5.7 & 8.0 |

### 七、优化器与 8.0 新特性（10 个）
| # | 案例 | 难度 | 版本 |
|---|------|------|------|
| 85 | [降序索引消除 filesort](docs/cases/optimizer/85-descending-index.md) | ⭐⭐ | 5.7 & 8.0 |
| 86 | [函数索引优化 DATE 函数查询](docs/cases/optimizer/86-functional-index.md) | ⭐⭐ | 8.0+ |
| 87 | [直方图统计优化选错索引](docs/cases/optimizer/87-histogram-statistics.md) | ⭐⭐⭐ | 8.0+ |
| 88 | [CTE 递归查询优化树形结构](docs/cases/optimizer/88-cte-recursive.md) | ⭐⭐ | 8.0+ |
| 89 | [窗口函数替代相关子查询](docs/cases/optimizer/89-window-function.md) | ⭐⭐ | 8.0+ |
| 90 | [优化器 Hint 实战](docs/cases/optimizer/90-optimizer-hint.md) | ⭐⭐ | 5.7 & 8.0 |
| 91 | [派生条件下推优化](docs/cases/optimizer/91-derived-condition-pushdown.md) | ⭐⭐⭐ | 5.7 & 8.0 |
| 92 | [大批量 UPDATE 分批优化](docs/cases/optimizer/92-batch-update.md) | ⭐⭐ | 5.7 & 8.0 |
| 93 | [慢查询排查方法论](docs/cases/optimizer/93-slow-query-diagnosis.md) | ⭐⭐⭐ | 5.7 & 8.0 |
| 94 | [MySQL 8.0 并行查询 (Parallel Execution)](docs/cases/optimizer/94-parallel-execution.md) | ⭐⭐⭐ | 8.0.27+ |

### 八、TiDB 分布式优化（22 个）
| # | 案例 | 难度 | 版本 |
|---|------|------|------|
| 95 | [TiDB EXPLAIN 算子树解读](docs/cases/tidb/95-tidb-explain-tree.md) | ⭐⭐ | TiDB |
| 96 | [协处理器下推优化](docs/cases/tidb/96-coprocessor-pushdown.md) | ⭐⭐⭐ | TiDB |
| 97 | [AUTO_RANDOM 避免写热点](docs/cases/tidb/97-auto-random.md) | ⭐⭐ | TiDB |
| 98 | [TiDB 统计信息管理](docs/cases/tidb/98-tidb-statistics.md) | ⭐⭐⭐ | TiDB |
| 99 | [TiDB 事务模型对比](docs/cases/tidb/99-tidb-transaction.md) | ⭐⭐⭐ | TiDB |
| 100 | [IndexLookUp 回表与覆盖索引](docs/cases/tidb/100-index-lookup.md) | ⭐⭐ | TiDB |
| 101 | [TiFlash 列存与 MPP 分析加速](docs/cases/tidb/101-tiflash-mpp.md) | ⭐⭐⭐ | TiDB |
| 102 | [TiDB GC 机制与长事务影响](docs/cases/tidb/102-tidb-gc.md) | ⭐⭐⭐ | TiDB |
| 103 | [Follower Read 读写分离](docs/cases/tidb/103-follower-read.md) | ⭐⭐ | TiDB |
| 104 | [TiDB 内存控制与 OOM 防护](docs/cases/tidb/104-tidb-memory-oom.md) | ⭐⭐⭐ | TiDB |
| 105 | [TiDB Join 算法选择](docs/cases/tidb/105-tidb-join-algorithms.md) | ⭐⭐⭐ | TiDB |
| 106 | [TiDB 在线 DDL 机制](docs/cases/tidb/106-tidb-online-ddl.md) | ⭐⭐ | TiDB |
| 107 | [TiDB Plan Cache 执行计划缓存](docs/cases/tidb/107-tidb-plan-cache.md) | ⭐⭐ | TiDB |
| 108 | [TiDB Stale Read 历史读优化](docs/cases/tidb/108-tidb-stale-read.md) | ⭐⭐ | TiDB |
| 109 | [Region 热点调度与 Split 策略](docs/cases/tidb/109-region-hotspot.md) | ⭐⭐⭐ | TiDB |
| 110 | [SQL Binding 执行计划锁定 (SPM)](docs/cases/tidb/110-sql-binding.md) | ⭐⭐⭐ | TiDB |
| 111 | [TiDB 分区表优化](docs/cases/tidb/111-tidb-partition.md) | ⭐⭐ | TiDB |
| 112 | [TiDB Dashboard 诊断实战](docs/cases/tidb/112-tidb-dashboard.md) | ⭐⭐ | TiDB |
| 113 | [TiDB 锁机制深度解析](docs/cases/tidb/113-tidb-lock-deep.md) | ⭐⭐⭐ | TiDB |
| 114 | [分布式 Sequence 自增方案](docs/cases/tidb/114-tidb-sequence.md) | ⭐⭐ | TiDB |
| 115 | [TiDB CTE 与临时表优化](docs/cases/tidb/115-tidb-cte.md) | ⭐⭐ | TiDB |
| 116 | [TiDB Cost Model 与优化器 Hint 进阶](docs/cases/tidb/116-tidb-cost-hint.md) | ⭐⭐⭐ | TiDB |
## 🛠️ 项目结构

```
sql-lab/
├── docs/                  # VitePress 文档站
│   ├── .vitepress/        # 配置 + 自定义组件
│   ├── guide/             # 使用指南
│   └── cases/             # 116 篇案例文档
├── sql/cases/             # 可运行 SQL（schema + seed + bad + good）
├── scripts/run-case.sh    # 一键运行案例
├── docker-compose.yml     # MySQL 5.7 + 8.0 + TiDB
├── .github/workflows/     # CI: SQL 校验 + 文档部署
└── CONTRIBUTING.md        # 贡献指南
```

每个案例的目录结构：

```
sql/cases/1-deep-pagination/
├── case.yml          # 元数据（标题/分类/难度/版本）
├── schema.sql        # 建表 + 索引
├── seed.sql          # 造数据（存储过程批量插入）
├── bad.sql           # 问题 SQL
├── good.sql          # 优化后 SQL
├── setup-good.sql    # [可选] DDL/SESSION 变更（如加索引）
└── expected/         # 参考 EXPLAIN 结果
```

## ⚙️ 运行参数

```bash
# 默认使用 MySQL 8.0
./scripts/run-case.sh 1-deep-pagination

# 指定版本
./scripts/run-case.sh 1-deep-pagination --ver 5.7
./scripts/run-case.sh 1-deep-pagination --ver 8.0

# 跳过造数据（已运行过的案例加速复跑）
./scripts/run-case.sh 1-deep-pagination --no-seed
```

## 🤝 贡献

欢迎贡献新案例！请阅读 [CONTRIBUTING.md](CONTRIBUTING.md) 了解如何添加一个案例。

我们特别欢迎以下方向的贡献：
- 🏭 真实生产中遇到的优化案例（请脱敏）
- 🆕 MySQL 8.0 新特性（CTE、窗口函数、Hash Join）的优化实践
- 🔀 TiDB / OceanBase 等兼容数据库的差异案例
- 📊 更多数据量级（千万级、亿级）的性能对比

## 📄 License

[MIT](LICENSE)
