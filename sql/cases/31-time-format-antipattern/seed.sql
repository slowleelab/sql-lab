-- ============================================================
-- 造数据: 20 万行订单数据
-- 两张表数据对应（时间值相同，只是存储类型不同）:
--   - t_time_bad:  created_at 用 VARCHAR(20) 存 'YYYY-MM-DD HH:MM:SS'
--   - t_time_good: created_at 用 DATETIME 存同样的时间值
-- created_at 分布在近 1 年内，并额外插入 2026-07-01 当天的固定数据，
-- 用于对比"查 7-1 当天数据"时三种反模式与正解的正确性差异。
-- ============================================================

DELIMITER $$
DROP PROCEDURE IF EXISTS sp_seed_time_format $$
CREATE PROCEDURE sp_seed_time_format()
BEGIN
    DECLARE i INT DEFAULT 0;
    DECLARE v_dt DATETIME;
    DECLARE v_str VARCHAR(20);

    -- 近 1 年内随机时间: NOW() 往前推 0~365 天 + 0~23 小时 + 0~59 分 + 0~59 秒
    -- bad 表存成字符串(格式 'YYYY-MM-DD HH:MM:SS')，good 表存成 DATETIME，值一一对应。
    SET autocommit = 0;

    WHILE i < 200000 DO
        SET v_dt  = DATE_SUB(NOW(),
                            INTERVAL FLOOR(RAND() * 365) DAY
                            + INTERVAL FLOOR(RAND() * 24) HOUR
                            + INTERVAL FLOOR(RAND() * 60) MINUTE
                            + INTERVAL FLOOR(RAND() * 60) SECOND);
        SET v_str = DATE_FORMAT(v_dt, '%Y-%m-%d %H:%i:%s');

        INSERT INTO t_time_bad (user_id, amount, created_at)
        VALUES (1 + FLOOR(RAND() * 100000), ROUND(1 + RAND() * 9999, 2), v_str);

        INSERT INTO t_time_good (user_id, amount, created_at)
        VALUES (1 + FLOOR(RAND() * 100000), ROUND(1 + RAND() * 9999, 2), v_dt);

        SET i = i + 1;

        IF i % 5000 = 0 THEN
            COMMIT;
        END IF;
    END WHILE;

    COMMIT;
    SET autocommit = 1;
END $$
DELIMITER ;

CALL sp_seed_time_format();
DROP PROCEDURE IF EXISTS sp_seed_time_format;

-- 插入 2026-07-01 当天的固定数据，便于 bad/good 对比测试
-- 三条记录覆盖当天早、中、晚，验证"查当天"的边界正确性:
--   - 08:00:00  (上午)
--   - 12:30:00  (中午)
--   - 23:59:59  (当天最后一秒, 验证闭开区间不会漏掉)
INSERT INTO t_time_bad (user_id, amount, created_at) VALUES
    (99901, 199.00, '2026-07-01 08:00:00'),
    (99902, 299.00, '2026-07-01 12:30:00'),
    (99903,  88.00, '2026-07-01 23:59:59');

INSERT INTO t_time_good (user_id, amount, created_at) VALUES
    (99901, 199.00, '2026-07-01 08:00:00'),
    (99902, 299.00, '2026-07-01 12:30:00'),
    (99903,  88.00, '2026-07-01 23:59:59');

-- 确认数据量一致
SELECT 't_time_bad'  AS tbl, COUNT(*) AS total_rows FROM t_time_bad
UNION ALL
SELECT 't_time_good', COUNT(*) FROM t_time_good;

-- 确认 2026-07-01 当天固定数据存在（两表对应）
SELECT 'bad'  AS tbl, COUNT(*) AS cnt_0701 FROM t_time_bad
WHERE created_at LIKE '2026-07-01%'
UNION ALL
SELECT 'good', COUNT(*) FROM t_time_good
WHERE created_at >= '2026-07-01 00:00:00' AND created_at < '2026-07-02 00:00:00';
-- 预期两表均至少 3 行（固定数据），加上随机数据中可能落在当天的行
