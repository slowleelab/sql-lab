-- bad.sql: AUTO_INCREMENT 导致的写入热点

-- 1. 查看 t_auto_inc 表的 Region 分布（所有新 ID 集中在最后一个 Region）
SHOW TABLE t_auto_inc REGIONS;

-- 2. 批量 INSERT 演示：所有新写入路由到同一个 Region
--    高并发下成为热点，单 TiKV 节点 CPU 100%，其他节点空闲
INSERT INTO t_auto_inc (name, val)
SELECT CONCAT('user_', seq), FLOOR(RAND() * 1000)
FROM (SELECT @rownum := @rownum + 1 AS seq FROM
      (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) a,
      (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) b,
      (SELECT @rownum := 0) r
) t LIMIT 1000;

-- 3. EXPLAIN 查看 INSERT 的执行计划
EXPLAIN INSERT INTO t_auto_inc (name, val) VALUES ('hotspot_test', 999);

-- 4. 再次查看 Region 分布——新增的 1000 行仍然在最后一个 Region
SHOW TABLE t_auto_inc REGIONS;
