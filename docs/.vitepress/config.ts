import { defineConfig } from 'vitepress'

// ────────────────────────────── 导航栏 ──────────────────────────────
const nav = [
  { text: '指南', link: '/guide/introduction' },
  { text: '案例', link: '/cases/' },
  { text: '📥 PDF', link: '/sql-lab-cases.pdf' },
  { text: 'GitHub', link: 'https://github.com/slowleelab/sql-lab' },
]

// ────────────────────────────── 侧边栏 ──────────────────────────────
const sidebar = {
  '/guide/': [
    {
      text: '开始',
      items: [
        { text: '项目介绍', link: '/guide/introduction' },
        { text: '快速开始', link: '/guide/quick-start' },
        { text: '如何阅读案例', link: '/guide/how-to-read' },
      ],
    },
  ],
  '/cases/': [
    {
      text: '一、索引设计与失效',
      collapsed: false,
      items: [
        { text: '1 · 深度分页 LIMIT 大偏移', link: '/cases/indexing/1-deep-pagination' },
        { text: '2 · 联合索引最左前缀失效', link: '/cases/indexing/2-leftmost-prefix' },
        { text: '3 · 隐式类型转换致索引失效', link: '/cases/indexing/3-implicit-type-conversion' },
        { text: '4 · 函数操作致索引失效', link: '/cases/indexing/4-function-on-index' },
        { text: '5 · LIKE 前导通配符', link: '/cases/indexing/5-like-leading-wildcard' },
        { text: '6 · OR 条件与索引合并', link: '/cases/indexing/6-or-condition' },
        { text: '7 · 范围查询后列索引失效', link: '/cases/indexing/7-range-after-index' },
        { text: '8 · 覆盖索引避免回表', link: '/cases/indexing/8-covering-index' },
        { text: '9 · 索引下推 ICP', link: '/cases/indexing/9-index-condition-pushdown' },
        { text: '10 · 冗余索引清理', link: '/cases/indexing/10-redundant-index-cleanup' },
        { text: '11 · 前缀索引优化长字符串', link: '/cases/indexing/11-prefix-index' },
        { text: '12 · 索引选择性评估', link: '/cases/indexing/12-index-selectivity' },
        { text: '13 · 不可见索引（8.0）', link: '/cases/indexing/13-invisible-index' },
        { text: '14 · 自增主键跳跃与性能', link: '/cases/indexing/14-auto-increment-gap' },
        { text: '15 · 索引合并 Index Merge 陷阱', link: '/cases/indexing/15-index-merge-pitfall' },
        { text: '16 · 索引跳跃扫描 Skip Scan', link: '/cases/indexing/16-skip-scan' },
        { text: '17 · 游标分页替代深分页', link: '/cases/indexing/17-cursor-pagination' },
        { text: '18 · 全文索引 FULLTEXT 替代 LIKE', link: '/cases/indexing/18-fulltext-search' },
        { text: '19 · 自适应哈希索引 AHI 调优', link: '/cases/indexing/19-adaptive-hash-index' },
        { text: '20 · Change Buffer 二级索引写入加速', link: '/cases/indexing/20-change-buffer' },
      ],
    },
    {
      text: '二、查询改写',
      collapsed: false,
      items: [
        { text: '21 · 子查询改写为 JOIN', link: '/cases/query-rewrite/21-subquery-to-join' },
        { text: '22 · COUNT(*) 慢查询优化', link: '/cases/query-rewrite/22-count-optimization' },
        { text: '23 · GROUP BY filesort 优化', link: '/cases/query-rewrite/23-group-by-filesort' },
        { text: '24 · 大 IN 列表优化', link: '/cases/query-rewrite/24-large-in-list' },
        { text: '25 · EXISTS vs IN', link: '/cases/query-rewrite/25-exists-vs-in' },
        { text: '26 · DISTINCT 优化', link: '/cases/query-rewrite/26-distinct-optimization' },
        { text: '27 · NOT IN vs LEFT JOIN IS NULL', link: '/cases/query-rewrite/27-not-in-vs-left-join' },
        { text: '28 · UNION vs UNION ALL', link: '/cases/query-rewrite/28-union-vs-union-all' },
        { text: '29 · ORDER BY LIMIT 无索引优化', link: '/cases/query-rewrite/29-orderby-limit-no-index' },
        { text: '30 · HAVING 改 WHERE 提前过滤', link: '/cases/query-rewrite/30-having-to-where' },
        { text: '31 · LIMIT 1 优化 EXISTS', link: '/cases/query-rewrite/31-limit1-exists' },
        { text: '32 · 时区与 TIMESTAMP vs DATETIME', link: '/cases/query-rewrite/32-timestamp-vs-datetime' },
        { text: '33 · 时间格式使用错误与最佳实践', link: '/cases/query-rewrite/33-time-format-antipattern' },
        { text: '34 · SQL 反模式与正确写法量化对比', link: '/cases/query-rewrite/34-sql-antipatterns' },
        { text: '35 · EXPLAIN FORMAT=JSON 详细成本树', link: '/cases/query-rewrite/35-explain-format-json' },
      ],
    },
    {
      text: '三、JOIN 优化',
      collapsed: false,
      items: [
        { text: '36 · 小表驱动大表', link: '/cases/join/36-small-drive-large' },
        { text: '37 · 被驱动表无索引的灾难', link: '/cases/join/37-driven-no-index' },
        { text: '38 · Hash Join vs BNL', link: '/cases/join/38-hash-join-vs-bnl' },
        { text: '39 · 多表 JOIN 顺序控制', link: '/cases/join/39-join-order' },
        { text: '40 · 自连接查询优化', link: '/cases/join/40-self-join-optimization' },
        { text: '41 · JOIN + GROUP BY 聚合优化', link: '/cases/join/41-join-group-by-optimization' },
        { text: '42 · 派生表物化优化', link: '/cases/join/42-derived-table-materialization' },
        { text: '43 · STRAIGHT_JOIN 强制驱动顺序', link: '/cases/join/43-straight-join' },
        { text: '44 · LEFT JOIN 改 INNER JOIN', link: '/cases/join/44-left-join-to-inner' },
      ],
    },
    {
      text: '四、DDL 与大表',
      collapsed: false,
      items: [
        { text: '45 · 大表加索引 Online DDL', link: '/cases/ddl/45-online-ddl' },
        { text: '46 · 大表增删列 INSTANT 操作全解', link: '/cases/ddl/46-large-table-add-drop-column' },
        { text: '47 · TEXT/BLOB 字段陷阱', link: '/cases/ddl/47-text-blob-pitfall' },
        { text: '48 · 大表 DELETE 分批', link: '/cases/ddl/48-batch-delete' },
        { text: '49 · 分区表 RANGE 分区优化', link: '/cases/ddl/49-partition-range' },
        { text: '50 · 大表批量 INSERT 优化', link: '/cases/ddl/50-batch-insert-optimization' },
        { text: '51 · OPTIMIZE TABLE 碎片整理', link: '/cases/ddl/51-optimize-table-fragmentation' },
        { text: '52 · 大表加列 INSTANT（8.0）', link: '/cases/ddl/52-instant-add-column' },
        { text: '53 · 修改字段类型锁表', link: '/cases/ddl/53-modify-column-type' },
        { text: '54 · 大字段垂直拆表', link: '/cases/ddl/54-vertical-split-text' },
        { text: '55 · 字段类型与长度选择最佳实践', link: '/cases/ddl/55-field-type-best-practice' },
        { text: '56 · 数据建模方法论与建表清单', link: '/cases/ddl/56-data-modeling-guide' },
        { text: '57 · 设计决策背后的理论依据', link: '/cases/ddl/57-design-decisions-theory' },
        { text: '58 · SELECT INTO OUTFILE 大数据导出', link: '/cases/ddl/58-select-into-outfile' },
      ],
    },
    {
      text: '五、架构级优化',
      collapsed: false,
      items: [
        { text: '59 · 多条件动态筛选索引设计', link: '/cases/architecture/59-dynamic-filter' },
        { text: '60 · 报表统计汇总表', link: '/cases/architecture/60-summary-table' },
        { text: '61 · 冷热数据分离', link: '/cases/architecture/61-hot-cold-separation' },
        { text: '62 · 秒杀场景库存扣减', link: '/cases/architecture/62-flash-sale-stock' },
        { text: '63 · 读写分离架构', link: '/cases/architecture/63-read-write-splitting' },
        { text: '64 · JSON 字段使用模式', link: '/cases/architecture/64-json-column-pattern' },
        { text: '65 · 软删除设计模式', link: '/cases/architecture/65-soft-delete-pattern' },
        { text: '66 · 分库分表路由策略', link: '/cases/architecture/66-sharding-route' },
        { text: '67 · 缓存穿透与布隆过滤器', link: '/cases/architecture/67-cache-penetration' },
        { text: '68 · 自增主键耗尽与分布式 ID', link: '/cases/architecture/68-auto-inc-exhaustion' },
        { text: '69 · 自增序列 8 个坑全景手册', link: '/cases/architecture/69-auto-increment-pitfalls' },
        { text: '70 · 连接池与 max_connections 耗尽诊断', link: '/cases/architecture/70-connection-pool-exhaustion' },
        { text: '71 · HikariCP/Druid 连接池调优', link: '/cases/architecture/71-connection-pool-tuning' },
        { text: '72 · InnoDB Buffer Pool 调优', link: '/cases/architecture/72-innodb-buffer-pool' },
        { text: '73 · Buffer Pool 重启预热 (Warmup)', link: '/cases/architecture/73-buffer-pool-warmup' },
      ],
    },
    {
      text: '六、事务与锁',
      collapsed: false,
      items: [
        { text: '74 · 死锁排查与分析', link: '/cases/transaction/74-deadlock-analysis' },
        { text: '75 · 间隙锁导致插入阻塞', link: '/cases/transaction/75-gap-lock-insert-block' },
        { text: '76 · SELECT FOR UPDATE 锁范围', link: '/cases/transaction/76-select-for-update-scope' },
        { text: '77 · 乐观锁与悲观锁对比', link: '/cases/transaction/77-optimistic-vs-pessimistic-lock' },
        { text: '78 · 幻读问题与解决', link: '/cases/transaction/78-phantom-read' },
        { text: '79 · 死锁重试与超时处理', link: '/cases/transaction/79-deadlock-retry-timeout' },
        { text: '80 · 唯一索引并发插入冲突', link: '/cases/transaction/80-unique-index-concurrent-insert' },
        { text: '81 · 长事务危害', link: '/cases/transaction/81-long-transaction-harm' },
        { text: '82 · RC vs RR 隔离级别', link: '/cases/transaction/82-rc-vs-rr-isolation' },
        { text: '83 · undo 表空间膨胀与 Purge', link: '/cases/transaction/83-undo-tablespace' },
        { text: '84 · 慢查询排查与锁等待定位', link: '/cases/transaction/84-slow-query-diagnosis' },
      ],
    },
    {
      text: '七、优化器与 8.0 新特性',
      collapsed: false,
      items: [
        { text: '85 · 降序索引消除 filesort', link: '/cases/optimizer/85-descending-index' },
        { text: '86 · 函数索引（8.0）', link: '/cases/optimizer/86-functional-index' },
        { text: '87 · 直方图统计优化', link: '/cases/optimizer/87-histogram-statistics' },
        { text: '88 · CTE 递归查询优化', link: '/cases/optimizer/88-cte-recursive' },
        { text: '89 · 窗口函数替代自连接', link: '/cases/optimizer/89-window-function' },
        { text: '90 · 优化器 Hint 实战', link: '/cases/optimizer/90-optimizer-hint' },
        { text: '91 · 派生条件下推（8.0）', link: '/cases/optimizer/91-derived-condition-pushdown' },
        { text: '92 · 大批量 UPDATE 分批优化', link: '/cases/optimizer/92-batch-update' },
        { text: '93 · 慢查询排查方法论', link: '/cases/optimizer/93-slow-query-diagnosis' },
        { text: '94 · MySQL 8.0 并行查询', link: '/cases/optimizer/94-parallel-execution' },
      ],
    },
    {
      text: '八、TiDB 分布式优化',
      collapsed: false,
      items: [
        { text: '95 · TiDB EXPLAIN 算子树解读', link: '/cases/tidb/95-tidb-explain-tree' },
        { text: '96 · 协处理器下推优化', link: '/cases/tidb/96-coprocessor-pushdown' },
        { text: '97 · AUTO_RANDOM 避免写热点', link: '/cases/tidb/97-auto-random' },
        { text: '98 · TiDB 统计信息管理', link: '/cases/tidb/98-tidb-statistics' },
        { text: '99 · TiDB 事务模型对比', link: '/cases/tidb/99-tidb-transaction' },
        { text: '100 · IndexLookUp 回表与覆盖索引', link: '/cases/tidb/100-index-lookup' },
        { text: '101 · TiFlash 列存与 MPP 分析加速', link: '/cases/tidb/101-tiflash-mpp' },
        { text: '102 · TiDB GC 机制与长事务影响', link: '/cases/tidb/102-tidb-gc' },
        { text: '103 · Follower Read 读写分离', link: '/cases/tidb/103-follower-read' },
        { text: '104 · TiDB 内存控制与 OOM 防护', link: '/cases/tidb/104-tidb-memory-oom' },
        { text: '105 · TiDB Join 算法选择', link: '/cases/tidb/105-tidb-join-algorithms' },
        { text: '106 · TiDB 在线 DDL 机制', link: '/cases/tidb/106-tidb-online-ddl' },
        { text: '107 · TiDB Plan Cache 执行计划缓存', link: '/cases/tidb/107-tidb-plan-cache' },
        { text: '108 · TiDB Stale Read 历史读优化', link: '/cases/tidb/108-tidb-stale-read' },
        { text: '109 · Region 热点调度与 Split 策略', link: '/cases/tidb/109-region-hotspot' },
        { text: '110 · SQL Binding 执行计划锁定 (SPM)', link: '/cases/tidb/110-sql-binding' },
        { text: '111 · TiDB 分区表优化', link: '/cases/tidb/111-tidb-partition' },
        { text: '112 · TiDB Dashboard 诊断实战', link: '/cases/tidb/112-tidb-dashboard' },
        { text: '113 · TiDB 锁机制深度解析', link: '/cases/tidb/113-tidb-lock-deep' },
        { text: '114 · 分布式 Sequence 自增方案', link: '/cases/tidb/114-tidb-sequence' },
        { text: '115 · TiDB CTE 与临时表优化', link: '/cases/tidb/115-tidb-cte' },
        { text: '116 · TiDB Cost Model 与优化器 Hint 进阶', link: '/cases/tidb/116-tidb-cost-hint' },
      ],
    },
  ],
}

// ────────────────────────────── 站点配置 ──────────────────────────────
export default defineConfig({
  title: 'SQL Lab',
  description: '一套能跑、能量化对比的 MySQL + TiDB 优化实战案例集',
  lang: 'zh-CN',
  lastUpdated: true,
  cleanUrls: true,

  // GitHub Pages 部署在 /sql-lab/ 子路径下
  base: '/sql-lab/',

  // 站点 URL（用于 sitemap 和 canonical 链接）
  sitemap: {
    hostname: 'https://slowleelab.github.io/sql-lab/',
  },

  head: [
    ['meta', { name: 'theme-color', content: '#3aa675' }],
    ['link', { rel: 'icon', href: '/sql-lab/favicon.svg' }],

    // SEO: 关键词
    ['meta', { name: 'keywords', content: 'MySQL优化,SQL优化,EXPLAIN,索引优化,MySQL 8.0,数据库性能,Docker,慢查询,事务锁,查询改写,TiDB,分布式数据库,NewSQL,TiKV,coprocessor' }],

    // Open Graph（社交分享卡片）
    ['meta', { property: 'og:site_name', content: 'SQL Lab' }],
    ['meta', { property: 'og:type', content: 'website' }],
    ['meta', { property: 'og:title', content: 'SQL Lab · 102 个能跑的 MySQL/TiDB 优化实战案例' }],
    ['meta', { property: 'og:description', content: '一套能跑、能量化对比的 MySQL 优化实战案例集。102 个精选案例，8 大场景，覆盖 MySQL 5.7/8.0 和 TiDB，Docker 一键复现，bad/good EXPLAIN 量化对比。' }],
    ['meta', { property: 'og:url', content: 'https://slowleelab.github.io/sql-lab/' }],
    ['meta', { property: 'og:image', content: 'https://slowleelab.github.io/sql-lab/og-image.svg' }],

    // Twitter Card
    ['meta', { name: 'twitter:card', content: 'summary_large_image' }],
    ['meta', { name: 'twitter:title', content: 'SQL Lab · 102 个能跑的 MySQL/TiDB 优化实战案例' }],
    ['meta', { name: 'twitter:description', content: '一套能跑、能量化对比的 MySQL 优化实战案例集。Docker 一键复现，bad/good EXPLAIN 量化对比。' }],
    ['meta', { name: 'twitter:image', content: 'https://slowleelab.github.io/sql-lab/og-image.svg' }],
  ],

  themeConfig: {
    nav,
    sidebar,

    logo: '/favicon.svg',

    search: {
      provider: 'local',
    },

    outline: {
      label: '本页目录',
      level: [2, 3],
    },

    docFooter: {
      prev: '上一篇',
      next: '下一篇',
    },

    socialLinks: [
      { icon: 'github', link: 'https://github.com/slowleelab/sql-lab' },
    ],

    footer: {
      message: 'MIT Licensed',
      copyright: 'Copyright © 2026 SQL Lab',
    },

    lastUpdatedText: '最后更新',
  },
})
