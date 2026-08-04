# 案例标题重写候选表 (v3)

> 自动生成,共 **112** 个案例。
>
> **使用流程**:
> 1. 浏览候选,挑一个最像人话的填到"确认标题"列(或直接改原 markdown 后再跑 --scan)
> 2. 留空表示保持"场景痛点"
> 3. 保存后运行 `node scripts/rewrite-titles.js --apply` 批量替换

> **候选风格**:
> - 候选 1: [数字]+[动词]+[画面] (推荐) 
> - 候选 2: 现象直陈 (适合没有具体数字的)
> - 候选 3: 极简二词

| # | 章节 | 文件 | 候选 1 | 候选 2 | 候选 3 | 确认标题 | 关键数字 | 关键现象 |
|---|------|------|--------|--------|--------|----------|----------|----------|
|1|架构|`architecture/107-connection-pool-tuning.md`|2000失败：新连接申请失败|新连接申请失败|2000失败|2000失败：新连接申请失败|2000/1000|失败|
|2|架构|`architecture/108-innodb-buffer-pool.md`|100 万飙升|数据量从 100 万涨到 5000 万,飙升|100 万飙升|100 万飙升|100 万/5000 万/100|飙升|
|3|架构|`architecture/110-buffer-pool-warmup.md`|30 分钟告警：磁盘 IO 100% util|磁盘 IO 100% util,告警|30 分钟告警|30 分钟告警：磁盘 IO 100% util|30 分钟/100%/30|告警/慢|
|4|架构|`architecture/52-dynamic-filter.md`|20 万慢：查询却慢到 180ms|查询却慢到 180ms|20 万慢|20 万慢：查询却慢到 180ms|20 万/180ms/20|慢|
|5|架构|`architecture/53-summary-table.md`|350ms 触发的问题|加载需要 350ms|350ms + 30 万|350ms 触发的问题|350ms/30 万/30|—|
|6|架构|`architecture/54-hot-cold-separation.md`|90%慢：用户查"我的订单"越来越慢|用户查"我的订单"越来越慢|90%慢|90%慢：用户查"我的订单"越来越慢|90%/90|慢|
|7|架构|`architecture/55-flash-sale-stock.md`|130 单超卖|结果卖出了 130 单,超卖|130 单超卖|130 单超卖|130 单/100/130|超卖|
|8|架构|`architecture/56-read-write-splitting.md`|5000 QPS抖动：高峰期却抖动到 20-50ms|高峰期却抖动到 20-50ms|5000 QPS抖动|5000 QPS抖动：高峰期却抖动到 20-50ms|5000 QPS/50000 QPS/80%|抖动|
|9|架构|`architecture/57-json-column-pattern.md`|10 万慢：按颜色筛选商品却慢到 45ms|按颜色筛选商品却慢到 45ms|10 万慢|10 万慢：按颜色筛选商品却慢到 45ms|10 万/45ms/10|慢|
|10|架构|`architecture/58-soft-delete-pattern.md`|10 万：20% 已软删除|20% 已软删除|10 万 + 20%|10 万：20% 已软删除|10 万/20%/10|—|
|11|架构|`architecture/59-sharding-route.md`|订单量突破亿级后，单表无法承载，按|翻倍|—|订单量突破亿级后，单表无法承载，按|—|翻倍|
|12|架构|`architecture/60-cache-penetration.md`|100%耗尽|监控突然报警：数据库 CPU 100%、连接…,耗尽|100%耗尽|100%耗尽|100%/100/99999999|耗尽/穿透|
|13|架构|`architecture/61-auto-inc-exhaustion.md`|订单表突然无法写入|订单表突然无法写入|—|订单表突然无法写入|—|—|
|14|架构|`architecture/62-connection-pool-exhaustion.md`|10 分钟超时|大促开始 10 分钟,超时|10 分钟超时|10 分钟超时|10 分钟/10/1040|超时/慢|
|15|DDL|`ddl/105-select-into-outfile.md`|5000 万变慢|需要把 5000 万行订单表导出给数据团队做…,变慢|5000 万变慢|5000 万变慢|5000 万/2 小时/8 分钟|变慢/慢|
|16|DDL|`ddl/42-online-ddl.md`|200 万慢：导致按用户查询慢到不可用|导致按用户查询慢到不可用|200 万慢|200 万慢：导致按用户查询慢到不可用|200 万/200|慢|
|17|DDL|`ddl/43-text-blob-pitfall.md`|100ms慢：只有 10 万行文章|只有 10 万行文章,慢|100ms慢|100ms慢：只有 10 万行文章|100ms/10 万/20 条|慢|
|18|DDL|`ddl/44-batch-delete.md`|70%堆积：日志表堆积了大量 DEBUG 级别数据|日志表堆积了大量 DEBUG 级别数据|70%堆积|70%堆积：日志表堆积了大量 DEBUG 级别数据|70%/70|堆积|
|19|DDL|`ddl/45-partition-range.md`|96 万堆积：却仍要扫描跨越全部 12 个月数据的索引树|却仍要扫描跨越全部 12 个月数据的索引树,堆积|96 万堆积|96 万堆积：却仍要扫描跨越全部 12 个月数据的索引树|96 万/96/12|堆积|
|20|DDL|`ddl/46-batch-insert-optimization.md`|10 万：跑了 85 秒还没完成|跑了 85 秒还没完成|10 万 + 85 秒|10 万：跑了 85 秒还没完成|10 万/85 秒/10|—|
|21|DDL|`ddl/47-optimize-table-fragmentation.md`|20 万变慢：表只剩 6 万行有效数据|表只剩 6 万行有效数据,变慢|20 万变慢|20 万变慢：表只剩 6 万行有效数据|20 万/70%/6 万|变慢/慢|
|22|DDL|`ddl/48-instant-add-column.md`|500 万 触发的问题|表有 500 万行数据|500 万 + 500|500 万 触发的问题|500 万/500|—|
|23|DDL|`ddl/49-modify-column-type.md`|100 万：实际手机号只有 11 位|实际手机号只有 11 位|100 万 + 50|100 万：实际手机号只有 11 位|100 万/50/11|—|
|24|DDL|`ddl/50-vertical-split-text.md`|5KB：列表页只需要标题和摘要|列表页只需要标题和摘要|5KB + 45ms|5KB：列表页只需要标题和摘要|5KB/45ms|—|
|25|DDL|`ddl/51-field-type-best-practice.md`|100 万 触发的问题|表涨到 100 万行|100 万 + 20|100 万 触发的问题|100 万/20/50|—|
|26|索引|`indexing/01-deep-pagination.md`|10 万飙升：从 50ms 飙升到 2 秒以上|从 50ms 飙升到 2 秒以上|10 万飙升|10 万飙升：从 50ms 飙升到 2 秒以上|10 万/50ms/2 秒|飙升/告警/慢|
|27|索引|`indexing/02-leftmost-prefix.md`|50 万 触发的问题|50 万行的表查询要 2 秒|50 万 + 2 秒|50 万 触发的问题|50 万/2 秒/50|—|
|28|索引|`indexing/03-implicit-type-conversion.md`|号是数字类型（13800138000|号是数字类型（138|—|号是数字类型（13800138000|—|—|
|29|索引|`indexing/04-function-on-index.md`|30 万：created_at 有索引|created_at 有索引|30 万 + 2026|30 万：created_at 有索引|30 万/2026/30|—|
|30|索引|`indexing/05-like-leading-wildcard.md`|20 万：用户搜索框输入关键词|用户搜索框输入关键词|20 万 + 20|20 万：用户搜索框输入关键词|20 万/20|—|
|31|索引|`indexing/06-or-condition.md`|整个查询退化为全表扫描|退化|—|整个查询退化为全表扫描|—|退化|
|32|索引|`indexing/07-range-after-index.md`|1000：联合索引 (user_id|联合索引 (user_id|1000 + 500|1000：联合索引 (user_id|1000/500|—|
|33|索引|`indexing/08-covering-index.md`|100 条飙升|每页 100 条,飙升|100 条飙升|100 条飙升|100 条/30 万/50ms|飙升|
|34|索引|`indexing/09-index-condition-pushdown.md`|按手机号前缀 + 姓名模糊查询|按手机号前缀 + 姓|—|按手机号前缀 + 姓名模糊查询|—|—|
|35|索引|`indexing/10-redundant-index-cleanup.md`|12345：created_at) 两个索引|created_at) 两个索引|12345|12345：created_at) 两个索引|12345|—|
|36|索引|`indexing/103-adaptive-hash-index.md`|0.5ms 触发的问题|单次查询约 0.5ms|0.5ms + 99%|0.5ms 触发的问题|0.5ms/99%/95%|—|
|37|索引|`indexing/104-change-buffer.md`|3000 触发的问题|tps 仅有 3000|3000|3000 触发的问题|3000|—|
|38|索引|`indexing/11-prefix-index.md`|8mb变慢|utf8mb4 下每个字符最多 4 字节,变慢|8mb变慢|8mb变慢|8mb/255×/15 万|变慢/慢|
|39|索引|`indexing/12-index-selectivity.md`|订单状态表按 status 查询|订单状态表按 sta|—|订单状态表按 status 查询|—|—|
|40|索引|`indexing/13-invisible-index.md`|商品表按 category 查询,慢|慢|—|商品表按 category 查询,慢|—|慢|
|41|索引|`indexing/14-auto-increment-gap.md`|100000失败：自增主键 ID 出现了大量"跳号"|自增主键 ID 出现了大量"跳号",失败|100000失败|100000失败：自增主键 ID 出现了大量"跳号"|100000/100006/100001|失败/跳号|
|42|索引|`indexing/15-index-merge-pitfall.md`|状态为 1 或者城市为北京"的用户列表|状态为 1 或者城市|—|状态为 1 或者城市为北京"的用户列表|—|—|
|43|索引|`indexing/16-skip-scan.md`|2026：用户表有联合索引 (gender|用户表有联合索引 (gender|2026|2026：用户表有联合索引 (gender|2026|—|
|44|索引|`indexing/17-cursor-pagination.md`|翻到深页越来越慢|慢|—|翻到深页越来越慢|—|慢|
|45|索引|`indexing/18-fulltext-search.md`|用户输入关键词搜索文章正文|用户输入关键词搜索文|—|用户输入关键词搜索文章正文|—|—|
|46|JOIN|`join/33-small-drive-large.md`|5000 条 触发的问题|活动关联表只有 5000 条记录|5000 条 + 100 万|5000 条 触发的问题|5000 条/100 万/3 秒|—|
|47|JOIN|`join/34-driven-no-index.md`|10 万 触发的问题|10 万订单 + 30 万明细|10 万 + 30 万|10 万 触发的问题|10 万/30 万/10|—|
|48|JOIN|`join/35-hash-join-vs-bnl.md`|两张表 JOIN|两张表 JOIN|—|两张表 JOIN|—|—|
|49|JOIN|`join/36-join-order.md`|1000 行：优化器偶尔选错 JOIN 顺序|优化器偶尔选错 JOIN 顺序|1000 行 + 5 万|1000 行：优化器偶尔选错 JOIN 顺序|1000 行/5 万/20 万|—|
|50|JOIN|`join/37-self-join-optimization.md`|10 万 触发的问题|员工表有 10 万行|10 万 + 1.2 秒|10 万 触发的问题|10 万/1.2 秒/10|—|
|51|JOIN|`join/38-join-group-by-optimization.md`|100 万 触发的问题|订单表 100 万行|100 万 + 1 万|100 万 触发的问题|100 万/1 万/2.7 秒|—|
|52|JOIN|`join/39-derived-table-materialization.md`|100 次 触发的问题|访问次数超过 100 次的活跃用户"|100 次 + 20 万|100 次 触发的问题|100 次/20 万/100|—|
|53|JOIN|`join/40-straight-join.md`|50ms飙升|运营反馈"订单详情页"接口从 50ms 飙升…|50ms飙升|50ms飙升|50ms/2 秒/30 万|飙升|
|54|JOIN|`join/41-left-join-to-inner.md`|100 万 触发的问题|订单表 100 万行|100 万 + 10 万|100 万 触发的问题|100 万/10 万/3 秒|—|
|55|优化器|`optimizer/111-parallel-execution.md`|5 亿：即使有索引也要 40 秒+|即使有索引也要 40 秒+|5 亿 + 40 秒|5 亿：即使有索引也要 40 秒+|5 亿/40 秒/30%|—|
|56|优化器|`optimizer/72-descending-index.md`|20 条 触发的问题|间倒序取最近 20 条记录|20 条 + 20|20 条 触发的问题|20 条/20|—|
|57|优化器|`optimizer/73-functional-index.md`|2024慢：访问日志表按日期查询是再常见不过的需求|访问日志表按日期查询是再常见不过的需求,慢|2024慢|2024慢：访问日志表按日期查询是再常见不过的需求|2024/15|慢|
|58|优化器|`optimizer/74-histogram-statistics.md`|20 万变慢|任务表 t_task 有 20 万条记录,变慢|20 万变慢|20 万变慢|20 万/99%/20|变慢/慢|
|59|优化器|`optimizer/75-cte-recursive.md`|10 万 触发的问题|共约 10 万人|10 万 + 10|10 万 触发的问题|10 万/10|—|
|60|优化器|`optimizer/76-window-function.md`|10 万：产品需求是：查询每个部门薪资最高的员工|产品需求是：查询每个部门薪资最高的员工|10 万 + 10|10 万：产品需求是：查询每个部门薪资最高的员工|10 万/10/100|—|
|61|优化器|`optimizer/77-optimizer-hint.md`|10 行变慢：某个查询突然变慢|某个查询突然变慢|10 行变慢|10 行变慢：某个查询突然变慢|10 行/35 万/2ms|变慢/慢|
|62|优化器|`optimizer/78-derived-condition-pushdown.md`|100 万：10 万个用户|10 万个用户|100 万 + 10 万|100 万：10 万个用户|100 万/10 万/100|—|
|63|优化器|`optimizer/79-batch-update.md`|50 万飙升|一条 UPDATE 搞定？数据量 50 万行,飙升|50 万飙升|50 万飙升|50 万/30 秒/50|飙升/超时|
|64|优化器|`optimizer/80-slow-query-diagnosis.md`|90%飙升|生产数据库 CPU 飙升到 90%|90%飙升|90%飙升|90%/90|飙升/告警/慢|
|65|查询改写|`query-rewrite/106-explain-format-json.md`|12 触发的问题|经典的 EXPLAIN（12 列扁平表）只能…|12|12 触发的问题|12|—|
|66|查询改写|`query-rewrite/19-subquery-to-join.md`|5 万 触发的问题|5 万用户 + 20 万订单|5 万 + 20 万|5 万 触发的问题|5 万/20 万/20|—|
|67|查询改写|`query-rewrite/20-count-optimization.md`|50 万：订单总数|后台仪表盘显示订单总数，SELECT|50 万 + 400ms|50 万：订单总数|50 万/400ms/50|—|
|68|查询改写|`query-rewrite/21-group-by-filesort.md`|2 秒 触发的问题|每次打开要等 2 秒|2 秒|2 秒 触发的问题|2 秒|—|
|69|查询改写|`query-rewrite/22-large-in-list.md`|1000 触发的问题|批量查询传入上千个 ID 的 IN|1000|1000 触发的问题|1000|—|
|70|查询改写|`query-rewrite/23-exists-vs-in.md`|查询"技术部门的所有员工"|查询"技术部门的所有|—|查询"技术部门的所有员工"|—|—|
|71|查询改写|`query-rewrite/24-distinct-optimization.md`|20 万：约 90ms|约 90ms|20 万 + 90ms|20 万：约 90ms|20 万/90ms/20|—|
|72|查询改写|`query-rewrite/25-not-in-vs-left-join.md`|查询"没有下过订单的用户"|查询"没有下过订单的|—|查询"没有下过订单的用户"|—|—|
|73|查询改写|`query-rewrite/26-union-vs-union-all.md`|候两个查询结果根本没有重复行|重复|—|候两个查询结果根本没有重复行|—|重复|
|74|查询改写|`query-rewrite/27-orderby-limit-no-index.md`|10 条：浪费率 99.995%|浪费率 99.995%|10 条 + 20 万|10 条：浪费率 99.995%|10 条/20 万/99.995%|—|
|75|查询改写|`query-rewrite/28-having-to-where.md`|已支付订单数大于 5 的用户"|已支付订单数大于 5|—|已支付订单数大于 5 的用户"|—|—|
|76|查询改写|`query-rewrite/29-limit1-exists.md`|"有未支付订单的用户"|"有未支付订单的用户|—|"有未支付订单的用户"|—|—|
|77|查询改写|`query-rewrite/30-timestamp-vs-datetime.md`|2026 触发的问题|跑日报"统计 2026-07-01 当天订单…|2026|2026 触发的问题|2026|—|
|78|查询改写|`query-rewrite/31-time-format-antipattern.md`|20慢|2026-07-01 当天的订单",慢|20慢|20慢|20/2026|慢|
|79|查询改写|`query-rewrite/32-sql-antipatterns.md`|30 万抖动|表只有 30 万行,抖动|30 万抖动|30 万抖动|30 万/30|抖动/慢|
|80|TiDB|`tidb/100-tidb-sequence.md`|从 MySQL 迁移到 TiDB 后|从 MySQL 迁移|—|从 MySQL 迁移到 TiDB 后|—|—|
|81|TiDB|`tidb/101-tidb-cte.md`|你的做法是写死 N 层 LEFT JOIN|你的做法是写死 N|—|你的做法是写死 N 层 LEFT JOIN|—|—|
|82|TiDB|`tidb/102-tidb-cost-hint.md`|90%失败|90% 的记录都是成功状态（status=1…,失败|90%失败|90%失败|90%/90|失败|
|83|TiDB|`tidb/81-tidb-explain-tree.md`|你是一名有多年 MySQL 经验的 DBA|你是一名有多年 My|—|你是一名有多年 MySQL 经验的 DBA|—|—|
|84|TiDB|`tidb/82-coprocessor-pushdown.md`|TiDB 查询变慢,失败|失败 + 变慢|—|TiDB 查询变慢,失败|—|失败/变慢/慢|
|85|TiDB|`tidb/83-auto-random.md`|100%：监控显示某个 TiKV 节点的 CPU 一直…|监控显示某个 TiKV 节点的 CPU 一直…|100% + 100|100%：监控显示某个 TiKV 节点的 CPU 一直…|100%/100|—|
|86|TiDB|`tidb/84-tidb-statistics.md`|5 万飙升：多条核心查询 SQL 的延迟从原来的 10m…|多条核心查询 SQL 的延迟从原来的 10m…,飙升|5 万飙升|5 万飙升：多条核心查询 SQL 的延迟从原来的 10m…|5 万/10ms|飙升/告警|
|87|TiDB|`tidb/85-tidb-transaction.md`|9007重复：重复、余额不一致等数据问题|重复、余额不一致等数据问题|9007重复|9007重复：重复、余额不一致等数据问题|9007|重复|
|88|TiDB|`tidb/86-index-lookup.md`|2 万飙升：间从 5ms 飙升到 30ms|间从 5ms 飙升到 30ms|2 万飙升|2 万飙升：间从 5ms 飙升到 30ms|2 万/5ms/30ms|飙升/变慢/慢|
|89|TiDB|`tidb/87-tiflash-mpp.md`|500 万慢：TiDB 的报表查询越来越慢|TiDB 的报表查询越来越慢|500 万慢|500 万慢：TiDB 的报表查询越来越慢|500 万/10 秒/500|慢|
|90|TiDB|`tidb/88-tidb-gc.md`|10 万：检查发现最近执行了一批清理任务|检查发现最近执行了一批清理任务|10 万 + 1 万|10 万：检查发现最近执行了一批清理任务|10 万/1 万/10|—|
|91|TiDB|`tidb/89-follower-read.md`|10：你打开 Grafana 监控面板|你打开 Grafana 监控面板|10|10：你打开 Grafana 监控面板|10|—|
|92|TiDB|`tidb/90-tidb-memory-oom.md`|你被监控告警吵醒,失败|失败 + 告警|—|你被监控告警吵醒,失败|—|失败/告警/慢|
|93|TiDB|`tidb/91-tidb-join-algorithms.md`|200ms飙升|某个核心 JOIN 查询突然从 200ms …,飙升|200ms飙升|200ms飙升|200ms|飙升|
|94|TiDB|`tidb/92-tidb-online-ddl.md`|你习惯了这样的流程|你习惯了这样的流程|—|你习惯了这样的流程|—|—|
|95|TiDB|`tidb/93-tidb-plan-cache.md`|40%飙升：你检查了慢查询日志|你检查了慢查询日志,飙升|40%飙升|40%飙升：你检查了慢查询日志|40%/80%/60%|飙升/告警/慢|
|96|TiDB|`tidb/94-tidb-stale-read.md`|拉一次销售汇总报表,飙升|飙升 + 超时|—|拉一次销售汇总报表,飙升|—|飙升/超时/抖动|
|97|TiDB|`tidb/95-region-hotspot.md`|100%：某个 TiKV 节点的 CPU 持续 100…|某个 TiKV 节点的 CPU 持续 100…|100% + 30%|100%：某个 TiKV 节点的 CPU 持续 100…|100%/30%/60%|—|
|98|TiDB|`tidb/96-sql-binding.md`|50ms飙升：运营同学突然反馈"订单列表页加载超时"|运营同学突然反馈"订单列表页加载超时",飙升|50ms飙升|50ms飙升：运营同学突然反馈"订单列表页加载超时"|50ms/3 秒|飙升/超时|
|99|TiDB|`tidb/97-tidb-partition.md`|5 秒：MySQL 迁移到 TiDB 后|MySQL 迁移到 TiDB 后|5 秒 + 0.3 秒|5 秒：MySQL 迁移到 TiDB 后|5 秒/0.3 秒/10 倍|—|
|100|TiDB|`tidb/98-tidb-dashboard.md`|35%飙升：P99 延迟从 50ms 飙升到 5.2 秒|P99 延迟从 50ms 飙升到 5.2 秒|35%飙升|35%飙升：P99 延迟从 50ms 飙升到 5.2 秒|35%/92%/50ms|飙升/告警|
|101|TiDB|`tidb/99-tidb-lock-deep.md`|某电商平台在大促秒杀期间,耗尽|耗尽|—|某电商平台在大促秒杀期间,耗尽|—|耗尽|
|102|事务|`transaction/109-undo-tablespace.md`|30GB飙升：磁盘告警|某天巡检发现 undo_001 和|30GB飙升|30GB飙升：磁盘告警|30GB|飙升/告警|
|103|事务|`transaction/112-slow-query-diagnosis.md`|50%告警|告警"数据库 QPS 下降 50%"|50%告警|50%告警|50%/50|告警/慢|
|104|事务|`transaction/63-deadlock-analysis.md`|1213失败：导致部分订单处理失败、需要人工重试|导致部分订单处理失败、需要人工重试|1213失败|1213失败：导致部分订单处理失败、需要人工重试|1213/40001|失败|
|105|事务|`transaction/64-gap-lock-insert-block.md`|10阻塞：事务B尝试向该范围插入一个新账户（id=15…|事务B尝试向该范围插入一个新账户（id=15…,阻塞|10阻塞|10阻塞：事务B尝试向该范围插入一个新账户（id=15…|10/20/15|阻塞|
|106|事务|`transaction/65-select-for-update-scope.md`|1205阻塞：连非电子产品（如食品类 id=1）的库存扣减…|连非电子产品（如食品类 id=1）的库存扣减…,阻塞|1205阻塞|1205阻塞：连非电子产品（如食品类 id=1）的库存扣减…|1205|阻塞|
|107|事务|`transaction/66-optimistic-vs-pessimistic-lock.md`|发现同一商品的扣减请求全部串行排队|发现同一商品的扣减请|—|发现同一商品的扣减请求全部串行排队|—|—|
|108|事务|`transaction/67-phantom-read.md`|是否有交易记录（COUNT(*) = 0|是否有交易记录（CO|—|是否有交易记录（COUNT(*) = 0|—|—|
|109|事务|`transaction/68-deadlock-retry-timeout.md`|50 秒堆积|50 秒的等待期间连接池连接被占用,堆积|50 秒堆积|50 秒堆积|50 秒/50/1205|堆积/慢/雪崩|
|110|事务|`transaction/69-unique-index-concurrent-insert.md`|1062：SELECT 检查某条记录是否存在|SELECT 检查某条记录是否存在|1062 + 23000|1062：SELECT 检查某条记录是否存在|1062/23000|—|
|111|事务|`transaction/70-long-transaction-harm.md`|5 秒：高峰期甚至超过 10 秒|高峰期甚至超过 10 秒|5 秒 + 10 秒|5 秒：高峰期甚至超过 10 秒|5 秒/10 秒/10|—|
|112|事务|`transaction/71-rc-vs-rr-isolation.md`|100阻塞：客服需要锁定某个用户的已支付订单进行对账|客服需要锁定某个用户的已支付订单进行对账,阻塞|100阻塞|100阻塞：客服需要锁定某个用户的已支付订单进行对账|100/1205|阻塞|
