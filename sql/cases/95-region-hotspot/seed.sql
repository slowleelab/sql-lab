-- 插入 30 万行数据，ts 列存在明显倾斜：
--   约 15 万行集中在 '2026-07-28 12:00:00'（热点值）
--   其余 15 万行均匀分布在过去 30 天中
-- 写入时热点值的数据持续涌入同一个 Region，模拟写热点场景

DELIMITER $$
DROP PROCEDURE IF EXISTS sp_seed_region_test $$
CREATE PROCEDURE sp_seed_region_test()
BEGIN
    DECLARE i INT DEFAULT 0;
    DECLARE v_ts DATETIME;
    SET autocommit = 0;
    WHILE i < 300000 DO
        -- 50% 的行集中在热点 ts 值（模拟业务高峰写入同一时间点）
        IF i % 2 = 0 THEN
            SET v_ts = '2026-07-28 12:00:00';
        ELSE
            -- 其余 50% 均匀分散在过去 30 天的随机分钟
            SET v_ts = DATE_SUB('2026-07-28 12:00:00',
                INTERVAL FLOOR(RAND() * 30 * 24 * 60) MINUTE);
        END IF;

        INSERT INTO t_region_test (val, ts)
        VALUES (
            FLOOR(1 + RAND() * 9999),
            v_ts
        );
        SET i = i + 1;
        -- 每 5000 行提交一次，避免事务过大
        IF i % 5000 = 0 THEN COMMIT; END IF;
    END WHILE;
    COMMIT;
    SET autocommit = 1;
END $$
DELIMITER ;

CALL sp_seed_region_test();
DROP PROCEDURE IF EXISTS sp_seed_region_test;

-- 验证数据分布：热点值 vs 其他值的行数对比
SELECT
    CASE WHEN ts = '2026-07-28 12:00:00' THEN 'HOT' ELSE 'NORMAL' END AS category,
    COUNT(*) AS row_count
FROM t_region_test
GROUP BY CASE WHEN ts = '2026-07-28 12:00:00' THEN 'HOT' ELSE 'NORMAL' END;

SELECT COUNT(*) AS total_rows FROM t_region_test;
