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
        { text: '01 · 深度分页 LIMIT 大偏移', link: '/cases/indexing/01-deep-pagination' },
        { text: '02 · 联合索引最左前缀失效', link: '/cases/indexing/02-leftmost-prefix' },
        { text: '03 · 隐式类型转换致索引失效', link: '/cases/indexing/03-implicit-type-conversion' },
        { text: '04 · 函数操作致索引失效', link: '/cases/indexing/04-function-on-index' },
        { text: '05 · LIKE 前导通配符', link: '/cases/indexing/05-like-leading-wildcard' },
        { text: '06 · OR 条件与索引合并', link: '/cases/indexing/06-or-condition' },
        { text: '07 · 范围查询后列索引失效', link: '/cases/indexing/07-range-after-index' },
        { text: '08 · 覆盖索引避免回表', link: '/cases/indexing/08-covering-index' },
        { text: '09 · 索引下推 ICP', link: '/cases/indexing/09-index-condition-pushdown' },
        { text: '10 · 冗余索引清理', link: '/cases/indexing/10-redundant-index-cleanup' },
        { text: '11 · 前缀索引优化长字符串', link: '/cases/indexing/11-prefix-index' },
        { text: '12 · 索引选择性评估', link: '/cases/indexing/12-index-selectivity' },
        { text: '13 · 不可见索引（8.0）', link: '/cases/indexing/13-invisible-index' },
        { text: '14 · 自增主键跳跃与性能', link: '/cases/indexing/14-auto-increment-gap' },
        { text: '15 · 索引合并 Index Merge 陷阱', link: '/cases/indexing/15-index-merge-pitfall' },
        { text: '16 · 索引跳跃扫描 Skip Scan', link: '/cases/indexing/16-skip-scan' },
        { text: '17 · 游标分页替代深分页', link: '/cases/indexing/17-cursor-pagination' },
        { text: '18 · 全文索引 FULLTEXT 替代 LIKE', link: '/cases/indexing/18-fulltext-search' },
        { text: '103 · 自适应哈希索引 AHI 调优', link: '/cases/indexing/103-adaptive-hash-index' },
        { text: '104 · Change Buffer 二级索引写入加速', link: '/cases/indexing/104-change-buffer' },
      ],
    },
    {
      text: '二、查询改写',
      collapsed: false,
      items: [
        { text: '19 · 子查询改写为 JOIN', link: '/cases/query-rewrite/19-subquery-to-join' },
        { text: '20 · COUNT(*) 慢查询优化', link: '/cases/query-rewrite/20-count-optimization' },
        { text: '21 · GROUP BY filesort 优化', link: '/cases/query-rewrite/21-group-by-filesort' },
        { text: '22 · 大 IN 列表优化', link: '/cases/query-rewrite/22-large-in-list' },
        { text: '23 · EXISTS vs IN', link: '/cases/query-rewrite/23-exists-vs-in' },
        { text: '24 · DISTINCT 优化', link: '/cases/query-rewrite/24-distinct-optimization' },
        { text: '25 · NOT IN vs LEFT JOIN IS NULL', link: '/cases/query-rewrite/25-not-in-vs-left-join' },
        { text: '26 · UNION vs UNION ALL', link: '/cases/query-rewrite/26-union-vs-union-all' },
        { text: '27 · ORDER BY LIMIT 无索引优化', link: '/cases/query-rewrite/27-orderby-limit-no-index' },
        { text: '28 · HAVING 改 WHERE 提前过滤', link: '/cases/query-rewrite/28-having-to-where' },
        { text: '29 · LIMIT 1 优化 EXISTS', link: '/cases/query-rewrite/29-limit1-exists' },
        { text: '30 · 时区与 TIMESTAMP vs DATETIME', link: '/cases/query-rewrite/30-timestamp-vs-datetime' },
        { text: '31 · 时间格式使用错误与最佳实践', link: '/cases/query-rewrite/31-time-format-antipattern' },
        { text: '32 · SQL 反模式与正确写法量化对比', link: '/cases/query-rewrite/32-sql-antipatterns' },
        { text: '106 · EXPLAIN FORMAT=JSON 详细成本树', link: '/cases/query-rewrite/106-explain-format-json' },
      ],
    },
    {
      text: '三、JOIN 优化',
      collapsed: false,
      items: [
        { text: '33 · 小表驱动大表', link: '/cases/join/33-small-drive-large' },
        { text: '34 · 被驱动表无索引的灾难', link: '/cases/join/34-driven-no-index' },
        { text: '35 · Hash Join vs BNL', link: '/cases/join/35-hash-join-vs-bnl' },
        { text: '36 · 多表 JOIN 顺序控制', link: '/cases/join/36-join-order' },
        { text: '37 · 自连接查询优化', link: '/cases/join/37-self-join-optimization' },
        { text: '38 · JOIN + GROUP BY 聚合优化', link: '/cases/join/38-join-group-by-optimization' },
        { text: '39 · 派生表物化优化', link: '/cases/join/39-derived-table-materialization' },
        { text: '40 · STRAIGHT_JOIN 强制驱动顺序', link: '/cases/join/40-straight-join' },
        { text: '41 · LEFT JOIN 改 INNER JOIN', link: '/cases/join/41-left-join-to-inner' },
      ],
    },
    {
      text: '四、DDL 与大表',
      collapsed: false,
      items: [
        { text: '42 · 大表加索引 Online DDL', link: '/cases/ddl/42-online-ddl' },
        { text: '43 · TEXT/BLOB 字段陷阱', link: '/cases/ddl/43-text-blob-pitfall' },
        { text: '44 · 大表 DELETE 分批', link: '/cases/ddl/44-batch-delete' },
        { text: '45 · 分区表 RANGE 分区优化', link: '/cases/ddl/45-partition-range' },
        { text: '46 · 大表批量 INSERT 优化', link: '/cases/ddl/46-batch-insert-optimization' },
        { text: '47 · OPTIMIZE TABLE 碎片整理', link: '/cases/ddl/47-optimize-table-fragmentation' },
        { text: '48 · 大表加列 INSTANT（8.0）', link: '/cases/ddl/48-instant-add-column' },
        { text: '49 · 修改字段类型锁表', link: '/cases/ddl/49-modify-column-type' },
        { text: '50 · 大字段垂直拆表', link: '/cases/ddl/50-vertical-split-text' },
        { text: '51 · 字段类型与长度选择最佳实践', link: '/cases/ddl/51-field-type-best-practice' },
        { text: '105 · SELECT INTO OUTFILE 大数据导出', link: '/cases/ddl/105-select-into-outfile' },
      ],
    },
    {
      text: '五、架构级优化',
      collapsed: false,
      items: [
        { text: '52 · 多条件动态筛选索引设计', link: '/cases/architecture/52-dynamic-filter' },
        { text: '53 · 报表统计汇总表', link: '/cases/architecture/53-summary-table' },
        { text: '54 · 冷热数据分离', link: '/cases/architecture/54-hot-cold-separation' },
        { text: '55 · 秒杀场景库存扣减', link: '/cases/architecture/55-flash-sale-stock' },
        { text: '56 · 读写分离架构', link: '/cases/architecture/56-read-write-splitting' },
        { text: '57 · JSON 字段使用模式', link: '/cases/architecture/57-json-column-pattern' },
        { text: '58 · 软删除设计模式', link: '/cases/architecture/58-soft-delete-pattern' },
        { text: '59 · 分库分表路由策略', link: '/cases/architecture/59-sharding-route' },
        { text: '60 · 缓存穿透与布隆过滤器', link: '/cases/architecture/60-cache-penetration' },
        { text: '61 · 自增主键耗尽与分布式 ID', link: '/cases/architecture/61-auto-inc-exhaustion' },
        { text: '62 · 连接池与 max_connections 耗尽诊断', link: '/cases/architecture/62-connection-pool-exhaustion' },
        { text: '107 · HikariCP/Druid 连接池调优', link: '/cases/architecture/107-connection-pool-tuning' },
      ],
    },
    {
      text: '六、事务与锁',
      collapsed: false,
      items: [
        { text: '63 · 死锁排查与分析', link: '/cases/transaction/63-deadlock-analysis' },
        { text: '64 · 间隙锁导致插入阻塞', link: '/cases/transaction/64-gap-lock-insert-block' },
        { text: '65 · SELECT FOR UPDATE 锁范围', link: '/cases/transaction/65-select-for-update-scope' },
        { text: '66 · 乐观锁与悲观锁对比', link: '/cases/transaction/66-optimistic-vs-pessimistic-lock' },
        { text: '67 · 幻读问题与解决', link: '/cases/transaction/67-phantom-read' },
        { text: '68 · 死锁重试与超时处理', link: '/cases/transaction/68-deadlock-retry-timeout' },
        { text: '69 · 唯一索引并发插入冲突', link: '/cases/transaction/69-unique-index-concurrent-insert' },
        { text: '70 · 长事务危害', link: '/cases/transaction/70-long-transaction-harm' },
        { text: '71 · RC vs RR 隔离级别', link: '/cases/transaction/71-rc-vs-rr-isolation' },
      ],
    },
    {
      text: '七、优化器与 8.0 新特性',
      collapsed: false,
      items: [
        { text: '72 · 降序索引消除 filesort', link: '/cases/optimizer/72-descending-index' },
        { text: '73 · 函数索引（8.0）', link: '/cases/optimizer/73-functional-index' },
        { text: '74 · 直方图统计优化', link: '/cases/optimizer/74-histogram-statistics' },
        { text: '75 · CTE 递归查询优化', link: '/cases/optimizer/75-cte-recursive' },
        { text: '76 · 窗口函数替代自连接', link: '/cases/optimizer/76-window-function' },
        { text: '77 · 优化器 Hint 实战', link: '/cases/optimizer/77-optimizer-hint' },
        { text: '78 · 派生条件下推（8.0）', link: '/cases/optimizer/78-derived-condition-pushdown' },
        { text: '79 · 大批量 UPDATE 分批优化', link: '/cases/optimizer/79-batch-update' },
        { text: '80 · 慢查询排查方法论', link: '/cases/optimizer/80-slow-query-diagnosis' },
      ],
    },
    {
      text: '八、TiDB 分布式优化',
      collapsed: false,
      items: [
        { text: '81 · TiDB EXPLAIN 算子树解读', link: '/cases/tidb/81-tidb-explain-tree' },
        { text: '82 · 协处理器下推优化', link: '/cases/tidb/82-coprocessor-pushdown' },
        { text: '83 · AUTO_RANDOM 避免写热点', link: '/cases/tidb/83-auto-random' },
        { text: '84 · TiDB 统计信息管理', link: '/cases/tidb/84-tidb-statistics' },
        { text: '85 · TiDB 事务模型对比', link: '/cases/tidb/85-tidb-transaction' },
        { text: '86 · IndexLookUp 回表与覆盖索引', link: '/cases/tidb/86-index-lookup' },
        { text: '87 · TiFlash 列存与 MPP 分析加速', link: '/cases/tidb/87-tiflash-mpp' },
        { text: '88 · TiDB GC 机制与长事务影响', link: '/cases/tidb/88-tidb-gc' },
        { text: '89 · Follower Read 读写分离', link: '/cases/tidb/89-follower-read' },
        { text: '90 · TiDB 内存控制与 OOM 防护', link: '/cases/tidb/90-tidb-memory-oom' },
        { text: '91 · TiDB Join 算法选择', link: '/cases/tidb/91-tidb-join-algorithms' },
        { text: '92 · TiDB 在线 DDL 机制', link: '/cases/tidb/92-tidb-online-ddl' },
        { text: '93 · TiDB Plan Cache 执行计划缓存', link: '/cases/tidb/93-tidb-plan-cache' },
        { text: '94 · TiDB Stale Read 历史读优化', link: '/cases/tidb/94-tidb-stale-read' },
        { text: '95 · Region 热点调度与 Split 策略', link: '/cases/tidb/95-region-hotspot' },
        { text: '96 · SQL Binding 执行计划锁定 (SPM)', link: '/cases/tidb/96-sql-binding' },
        { text: '97 · TiDB 分区表优化', link: '/cases/tidb/97-tidb-partition' },
        { text: '98 · TiDB Dashboard 诊断实战', link: '/cases/tidb/98-tidb-dashboard' },
        { text: '99 · TiDB 锁机制深度解析', link: '/cases/tidb/99-tidb-lock-deep' },
        { text: '100 · 分布式 Sequence 自增方案', link: '/cases/tidb/100-tidb-sequence' },
        { text: '101 · TiDB CTE 与临时表优化', link: '/cases/tidb/101-tidb-cte' },
        { text: '102 · TiDB Cost Model 与优化器 Hint 进阶', link: '/cases/tidb/102-tidb-cost-hint' },
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
