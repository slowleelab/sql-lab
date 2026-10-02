-- 查询汇总表：数据已预聚合，直接按主键 stat_date 范围扫描
-- t_daily_summary 每天仅 1 行（365 行/年），查询毫秒级返回
-- 汇总表在生产中通过定时任务（如每天凌晨）增量更新
SELECT stat_date AS d,
       order_count AS cnt,
       total_amount AS total
FROM t_daily_summary
WHERE stat_date >= '2026-01-01'
ORDER BY stat_date;
