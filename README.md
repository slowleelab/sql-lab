# SQL Lab

> 🐳 一套**能跑、能量化对比**的 MySQL + TiDB 优化实战案例集  
> 每个案例都带真实数据，Docker 一键复现，bad/good EXPLAIN 量化对比

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![MySQL](https://img.shields.io/badge/MySQL-5.7%20%7C%208.0-blue.svg)](https://www.mysql.com/)
[![TiDB](https://img.shields.io/badge/TiDB-v7.5.1-purple.svg)](https://pingcap.com/)
[![CI](https://github.com/slowleelab/sql-lab/actions/workflows/validate-sql.yml/badge.svg)](https://github.com/slowleelab/sql-lab/actions)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](CONTRIBUTING.md)
[![Cases](https://img.shields.io/badge/cases-112-orange.svg)](docs/cases/)

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
./scripts/run-case.sh 01-deep-pagination
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

共 **102 个精选案例**，覆盖 MySQL + TiDB 优化的八大核心场景：

### 一、索引设计与失效（18 个）
| # | 案例 | 难度 | 版本 |
|---|------|------|------|
| 01 | [深度分页 LIMIT 大偏移](docs/cases/indexing/01-deep-pagination.md) | ⭐⭐ | 5.7 & 8.0 |
| 02 | [联合索引最左前缀失效](docs/cases/indexing/02-leftmost-prefix.md) | ⭐ | 5.7 & 8.0 |
| 03 | [隐式类型转换致索引失效](docs/cases/indexing/03-implicit-type-conversion.md) | ⭐⭐ | 5.7 & 8.0 |
| 04 | [函数操作致索引失效](docs/cases/indexing/04-function-on-index.md) | ⭐⭐ | 5.7 & 8.0 |
| 05 | [LIKE 前导通配符致索引失效](docs/cases/indexing/05-like-leading-wildcard.md) | ⭐ | 5.7 & 8.0 |
| 06 | [OR 条件与索引合并](docs/cases/indexing/06-or-condition.md) | ⭐⭐ | 5.7 & 8.0 |
| 07 | [范围查询后列索引失效](docs/cases/indexing/07-range-after-index.md) | ⭐⭐ | 5.7 & 8.0 |
| 08 | [覆盖索引避免回表](docs/cases/indexing/08-covering-index.md) | ⭐⭐ | 5.7 & 8.0 |
| 09 | [索引下推 ICP（Index Condition Pushdown）](docs/cases/indexing/09-index-condition-pushdown.md) | ⭐⭐⭐ | 5.6 & 5.7 & 8.0 |
| 10 | [冗余索引清理](docs/cases/indexing/10-redundant-index-cleanup.md) | ⭐⭐ | 5.7 & 8.0 |
| 11 | [前缀索引优化长字符串](docs/cases/indexing/11-prefix-index.md) | ⭐⭐ | 5.7 & 8.0 |
| 12 | [索引选择性评估](docs/cases/indexing/12-index-selectivity.md) | ⭐⭐ | 5.7 & 8.0 |
| 13 | [不可见索引 Invisible Index](docs/cases/indexing/13-invisible-index.md) | ⭐⭐ | 8.0+ |
| 14 | [自增主键跳跃与性能](docs/cases/indexing/14-auto-increment-gap.md) | ⭐⭐ | 5.7 & 8.0 |
| 15 | [索引合并 Index Merge 陷阱](docs/cases/indexing/15-index-merge-pitfall.md) | ⭐⭐ | 5.7 & 8.0 |
| 16 | [索引跳跃扫描 Skip Scan](docs/cases/indexing/16-skip-scan.md) | ⭐⭐ | 8.0+ |
| 17 | [游标分页替代深分页](docs/cases/indexing/17-cursor-pagination.md) | ⭐⭐ | 5.7 & 8.0 |
| 18 | [全文索引 FULLTEXT 替代 LIKE](docs/cases/indexing/18-fulltext-search.md) | ⭐⭐ | 5.7 & 8.0 |

### 二、查询改写（14 个）
| # | 案例 | 难度 | 版本 |
|---|------|------|------|
| 19 | [子查询改写为 JOIN](docs/cases/query-rewrite/19-subquery-to-join.md) | ⭐⭐ | 5.7 & 8.0 |
| 20 | [COUNT(*) 慢查询优化](docs/cases/query-rewrite/20-count-optimization.md) | ⭐⭐ | 5.7 & 8.0 |
| 21 | [GROUP BY filesort 优化](docs/cases/query-rewrite/21-group-by-filesort.md) | ⭐⭐ | 5.7 & 8.0 |
| 22 | [大 IN 列表优化](docs/cases/query-rewrite/22-large-in-list.md) | ⭐⭐ | 5.7 & 8.0 |
| 23 | [EXISTS vs IN 选择](docs/cases/query-rewrite/23-exists-vs-in.md) | ⭐⭐ | 5.7 & 8.0 |
| 24 | [DISTINCT 优化](docs/cases/query-rewrite/24-distinct-optimization.md) | ⭐⭐ | 5.7 & 8.0 |
| 25 | [NOT IN vs LEFT JOIN IS NULL](docs/cases/query-rewrite/25-not-in-vs-left-join.md) | ⭐⭐ | 5.7 & 8.0 |
| 26 | [UNION vs UNION ALL](docs/cases/query-rewrite/26-union-vs-union-all.md) | ⭐ | 5.7 & 8.0 |
| 27 | [ORDER BY LIMIT 无索引优化](docs/cases/query-rewrite/27-orderby-limit-no-index.md) | ⭐⭐ | 5.7 & 8.0 |
| 28 | [HAVING 改 WHERE 提前过滤](docs/cases/query-rewrite/28-having-to-where.md) | ⭐ | 5.7 & 8.0 |
| 29 | [LIMIT 1 优化 EXISTS 子查询](docs/cases/query-rewrite/29-limit1-exists.md) | ⭐⭐ | 5.7 & 8.0 |
| 30 | [时区与 TIMESTAMP vs DATETIME](docs/cases/query-rewrite/30-timestamp-vs-datetime.md) | ⭐⭐ | 5.7 & 8.0 |
| 31 | [时间格式使用错误与最佳实践](docs/cases/query-rewrite/31-time-format-antipattern.md) | ⭐⭐ | 5.7 & 8.0 |
| 32 | [SQL 反模式与正确写法量化对比](docs/cases/query-rewrite/32-sql-antipatterns.md) | ⭐⭐ | 5.7 & 8.0 |

### 三、JOIN 优化（9 个）
| # | 案例 | 难度 | 版本 |
|---|------|------|------|
| 33 | [JOIN 小表驱动大表](docs/cases/join/33-small-drive-large.md) | ⭐⭐ | 5.7 & 8.0 |
| 34 | [被驱动表无索引的灾难](docs/cases/join/34-driven-no-index.md) | ⭐⭐ | 5.7 & 8.0 |
| 35 | [Hash Join vs BNL](docs/cases/join/35-hash-join-vs-bnl.md) | ⭐⭐⭐ | 5.7 & 8.0 |
| 36 | [多表 JOIN 顺序控制](docs/cases/join/36-join-order.md) | ⭐⭐⭐ | 5.7 & 8.0 |
| 37 | [自连接查询优化](docs/cases/join/37-self-join-optimization.md) | ⭐⭐ | 5.7 & 8.0 |
| 38 | [JOIN + GROUP BY 聚合优化](docs/cases/join/38-join-group-by-optimization.md) | ⭐⭐⭐ | 5.7 & 8.0 |
| 39 | [派生表物化优化](docs/cases/join/39-derived-table-materialization.md) | ⭐⭐ | 5.7 & 8.0 |
| 40 | [STRAIGHT_JOIN 强制驱动顺序](docs/cases/join/40-straight-join.md) | ⭐⭐⭐ | 5.7 & 8.0 |
| 41 | [LEFT JOIN 改 INNER JOIN 释放优化器](docs/cases/join/41-left-join-to-inner.md) | ⭐⭐ | 5.7 & 8.0 |

### 四、DDL 与大表（10 个）
| # | 案例 | 难度 | 版本 |
|---|------|------|------|
| 42 | [大表加索引 Online DDL](docs/cases/ddl/42-online-ddl.md) | ⭐⭐⭐ | 5.7 & 8.0 |
| 43 | [TEXT/BLOB 字段性能陷阱](docs/cases/ddl/43-text-blob-pitfall.md) | ⭐⭐ | 5.7 & 8.0 |
| 44 | [大表 DELETE 分批](docs/cases/ddl/44-batch-delete.md) | ⭐⭐ | 5.7 & 8.0 |
| 45 | [分区表 RANGE 分区优化](docs/cases/ddl/45-partition-range.md) | ⭐⭐⭐ | 5.7 & 8.0 |
| 46 | [大表批量 INSERT 优化](docs/cases/ddl/46-batch-insert-optimization.md) | ⭐⭐ | 5.7 & 8.0 |
| 47 | [OPTIMIZE TABLE 碎片整理](docs/cases/ddl/47-optimize-table-fragmentation.md) | ⭐⭐ | 5.7 & 8.0 |
| 48 | [大表加列默认值 INSTANT 秒级完成](docs/cases/ddl/48-instant-add-column.md) | ⭐⭐ | 5.7 & 8.0 |
| 49 | [修改字段类型的锁行为差异](docs/cases/ddl/49-modify-column-type.md) | ⭐⭐⭐ | 5.7 & 8.0 |
| 50 | [大字段垂直拆表](docs/cases/ddl/50-vertical-split-text.md) | ⭐⭐ | 5.7 & 8.0 |
| 51 | [字段类型与长度选择最佳实践](docs/cases/ddl/51-field-type-best-practice.md) | ⭐⭐ | 5.7 & 8.0 |

### 五、架构级优化（11 个）
| # | 案例 | 难度 | 版本 |
|---|------|------|------|
| 52 | [多条件动态筛选索引设计](docs/cases/architecture/52-dynamic-filter.md) | ⭐⭐⭐ | 5.7 & 8.0 |
| 53 | [报表统计汇总表](docs/cases/architecture/53-summary-table.md) | ⭐⭐ | 5.7 & 8.0 |
| 54 | [冷热数据分离](docs/cases/architecture/54-hot-cold-separation.md) | ⭐⭐⭐ | 5.7 & 8.0 |
| 55 | [秒杀场景库存扣减](docs/cases/architecture/55-flash-sale-stock.md) | ⭐⭐⭐ | 5.7 & 8.0 |
| 56 | [读写分离架构](docs/cases/architecture/56-read-write-splitting.md) | ⭐⭐⭐ | 5.7 & 8.0 |
| 57 | [JSON 字段使用模式](docs/cases/architecture/57-json-column-pattern.md) | ⭐⭐ | 8.0+ |
| 58 | [软删除设计模式](docs/cases/architecture/58-soft-delete-pattern.md) | ⭐⭐ | 5.7 & 8.0 |
| 59 | [分库分表路由策略](docs/cases/architecture/59-sharding-route.md) | ⭐⭐⭐ | 5.7 & 8.0 |
| 60 | [缓存穿透与布隆过滤器](docs/cases/architecture/60-cache-penetration.md) | ⭐⭐⭐ | 5.7 & 8.0 |
| 61 | [自增主键耗尽与分布式 ID](docs/cases/architecture/61-auto-inc-exhaustion.md) | ⭐⭐⭐ | 5.7 & 8.0 |
| 62 | [连接池与 max_connections 耗尽诊断](docs/cases/architecture/62-connection-pool-exhaustion.md) | ⭐⭐ | 5.7 & 8.0 |

### 六、事务与锁（9 个）
| # | 案例 | 难度 | 版本 |
|---|------|------|------|
| 63 | [死锁排查与分析](docs/cases/transaction/63-deadlock-analysis.md) | ⭐⭐⭐ | 5.7 & 8.0 |
| 64 | [间隙锁导致插入阻塞](docs/cases/transaction/64-gap-lock-insert-block.md) | ⭐⭐⭐ | 5.7 & 8.0 |
| 65 | [SELECT FOR UPDATE 锁范围](docs/cases/transaction/65-select-for-update-scope.md) | ⭐⭐ | 5.7 & 8.0 |
| 66 | [乐观锁与悲观锁对比](docs/cases/transaction/66-optimistic-vs-pessimistic-lock.md) | ⭐⭐ | 5.7 & 8.0 |
| 67 | [幻读问题与解决](docs/cases/transaction/67-phantom-read.md) | ⭐⭐⭐ | 5.7 & 8.0 |
| 68 | [死锁重试与超时处理](docs/cases/transaction/68-deadlock-retry-timeout.md) | ⭐⭐ | 5.7 & 8.0 |
| 69 | [唯一索引并发插入冲突](docs/cases/transaction/69-unique-index-concurrent-insert.md) | ⭐⭐ | 5.7 & 8.0 |
| 70 | [长事务危害](docs/cases/transaction/70-long-transaction-harm.md) | ⭐⭐ | 5.7 & 8.0 |
| 71 | [RC vs RR 隔离级别锁行为差异](docs/cases/transaction/71-rc-vs-rr-isolation.md) | ⭐⭐⭐ | 5.7 & 8.0 |

### 七、优化器与 8.0 新特性（9 个）
| # | 案例 | 难度 | 版本 |
|---|------|------|------|
| 72 | [降序索引消除 filesort](docs/cases/optimizer/72-descending-index.md) | ⭐⭐ | 5.7 & 8.0 |
| 73 | [函数索引优化 DATE 函数查询](docs/cases/optimizer/73-functional-index.md) | ⭐⭐ | 8.0+ |
| 74 | [直方图统计优化选错索引](docs/cases/optimizer/74-histogram-statistics.md) | ⭐⭐⭐ | 8.0+ |
| 75 | [CTE 递归查询优化树形结构](docs/cases/optimizer/75-cte-recursive.md) | ⭐⭐ | 8.0+ |
| 76 | [窗口函数替代相关子查询](docs/cases/optimizer/76-window-function.md) | ⭐⭐ | 8.0+ |
| 77 | [优化器 Hint 实战](docs/cases/optimizer/77-optimizer-hint.md) | ⭐⭐ | 5.7 & 8.0 |
| 78 | [派生条件下推优化](docs/cases/optimizer/78-derived-condition-pushdown.md) | ⭐⭐⭐ | 5.7 & 8.0 |
| 79 | [大批量 UPDATE 分批优化](docs/cases/optimizer/79-batch-update.md) | ⭐⭐ | 5.7 & 8.0 |
| 80 | [慢查询排查方法论](docs/cases/optimizer/80-slow-query-diagnosis.md) | ⭐⭐⭐ | 5.7 & 8.0 |

### 八、TiDB 分布式优化（22 个）
| # | 案例 | 难度 | 版本 |
|---|------|------|------|
| 81 | [TiDB EXPLAIN 算子树解读](docs/cases/tidb/81-tidb-explain-tree.md) | ⭐⭐ | TiDB |
| 82 | [协处理器下推优化](docs/cases/tidb/82-coprocessor-pushdown.md) | ⭐⭐⭐ | TiDB |
| 83 | [AUTO_RANDOM 避免写热点](docs/cases/tidb/83-auto-random.md) | ⭐⭐ | TiDB |
| 84 | [TiDB 统计信息管理](docs/cases/tidb/84-tidb-statistics.md) | ⭐⭐⭐ | TiDB |
| 85 | [TiDB 事务模型对比](docs/cases/tidb/85-tidb-transaction.md) | ⭐⭐⭐ | TiDB |
| 86 | [IndexLookUp 回表与覆盖索引](docs/cases/tidb/86-index-lookup.md) | ⭐⭐ | TiDB |
| 87 | [TiFlash 列存与 MPP 分析加速](docs/cases/tidb/87-tiflash-mpp.md) | ⭐⭐⭐ | TiDB |
| 88 | [TiDB GC 机制与长事务影响](docs/cases/tidb/88-tidb-gc.md) | ⭐⭐⭐ | TiDB |
| 89 | [Follower Read 读写分离](docs/cases/tidb/89-follower-read.md) | ⭐⭐ | TiDB |
| 90 | [TiDB 内存控制与 OOM 防护](docs/cases/tidb/90-tidb-memory-oom.md) | ⭐⭐⭐ | TiDB |
| 91 | [TiDB Join 算法选择](docs/cases/tidb/91-tidb-join-algorithms.md) | ⭐⭐⭐ | TiDB |
| 92 | [TiDB 在线 DDL 机制](docs/cases/tidb/92-tidb-online-ddl.md) | ⭐⭐ | TiDB |
| 93 | [TiDB Plan Cache 执行计划缓存](docs/cases/tidb/93-tidb-plan-cache.md) | ⭐⭐ | TiDB |
| 94 | [TiDB Stale Read 历史读优化](docs/cases/tidb/94-tidb-stale-read.md) | ⭐⭐ | TiDB |
| 95 | [Region 热点调度与 Split 策略](docs/cases/tidb/95-region-hotspot.md) | ⭐⭐⭐ | TiDB |
| 96 | [SQL Binding 执行计划锁定 (SPM)](docs/cases/tidb/96-sql-binding.md) | ⭐⭐⭐ | TiDB |
| 97 | [TiDB 分区表优化](docs/cases/tidb/97-tidb-partition.md) | ⭐⭐ | TiDB |
| 98 | [TiDB Dashboard 诊断实战](docs/cases/tidb/98-tidb-dashboard.md) | ⭐⭐ | TiDB |
| 99 | [TiDB 锁机制深度解析](docs/cases/tidb/99-tidb-lock-deep.md) | ⭐⭐⭐ | TiDB |
| 100 | [分布式 Sequence 自增方案](docs/cases/tidb/100-tidb-sequence.md) | ⭐⭐ | TiDB |
| 101 | [TiDB CTE 与临时表优化](docs/cases/tidb/101-tidb-cte.md) | ⭐⭐ | TiDB |
| 102 | [TiDB Cost Model 与优化器 Hint 进阶](docs/cases/tidb/102-tidb-cost-hint.md) | ⭐⭐⭐ | TiDB |

## 🛠️ 项目结构

```
sql-lab/
├── docs/                  # VitePress 文档站
│   ├── .vitepress/        # 配置 + 自定义组件
│   ├── guide/             # 使用指南
│   └── cases/             # 102 篇案例文档
├── sql/cases/             # 可运行 SQL（schema + seed + bad + good）
├── scripts/run-case.sh    # 一键运行案例
├── docker-compose.yml     # MySQL 5.7 + 8.0 + TiDB
├── .github/workflows/     # CI: SQL 校验 + 文档部署
└── CONTRIBUTING.md        # 贡献指南
```

每个案例的目录结构：

```
sql/cases/01-deep-pagination/
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
./scripts/run-case.sh 01-deep-pagination

# 指定版本
./scripts/run-case.sh 01-deep-pagination --ver 5.7
./scripts/run-case.sh 01-deep-pagination --ver 8.0

# 跳过造数据（已运行过的案例加速复跑）
./scripts/run-case.sh 01-deep-pagination --no-seed
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
