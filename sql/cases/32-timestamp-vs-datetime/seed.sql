-- ============================================================
-- 造数据: 1000 行订单数据（重点不在数据量，在于时区行为）
-- 两张表插入完全相同的时间字面量 '2026-07-01 08:00:00'（UTC 时间）。
-- 关键观察点:
--   - t_time_bad(TIMESTAMP):  字面量在写入时被按"当前会话时区"转成 UTC 存储，
--                             读取时再按"读取时的会话时区"转回显示 -> 不同时区读出值不同。
--   - t_time_good(DATETIME):  字面量原样存储，无论会话时区如何，读出值始终一致。
-- ============================================================

-- 为了让两表的 TIMESTAMP 与 DATETIME 行为可复现、可对比，造数据前先把会话时区
-- 固定成 UTC(+00:00)。这样写入 '2026-07-01 08:00:00' 时:
--   - TIMESTAMP 列:  当作 UTC 08:00 写入，内部存 UTC 时间戳
--   - DATETIME  列:  原样存 '2026-07-01 08:00:00'
SET SESSION time_zone = '+00:00';

DELIMITER $$
DROP PROCEDURE IF EXISTS sp_seed_time_compare $$
CREATE PROCEDURE sp_seed_time_compare()
BEGIN
    DECLARE i INT DEFAULT 0;
    DECLARE v_created TIMESTAMP;
    DECLARE v_created_dt DATETIME;

    -- 用三批固定 UTC 时间，让时区错位在"按天统计"时清晰可见:
    --   批A 800 行: 2026-07-01 08:00:00 UTC  (上午订单)
    --   批B 100 行: 2026-07-01 20:00:00 UTC  (晚间订单, 在 +08:00 会话下显示成 7-2 04:00, 跨日!)
    --   批C 100 行: 2026-07-02 08:00:00 UTC  (次日上午订单)
    -- 这样 UTC 会话统计 7-1 = 900 行(A+B)，+08:00 会话统计 7-1 = 800 行(B 被推到 7-2)。
    SET autocommit = 0;

    WHILE i < 1000 DO
        IF i < 800 THEN
            SET v_created    = '2026-07-01 08:00:00';
            SET v_created_dt = '2026-07-01 08:00:00';
        ELSEIF i < 900 THEN
            SET v_created    = '2026-07-01 20:00:00';
            SET v_created_dt = '2026-07-01 20:00:00';
        ELSE
            SET v_created    = '2026-07-02 08:00:00';
            SET v_created_dt = '2026-07-02 08:00:00';
        END IF;

        INSERT INTO t_time_bad (user_id, amount, created_at, updated_at)
        VALUES (1 + FLOOR(RAND() * 100), ROUND(1 + RAND() * 9999, 2), v_created, v_created);

        INSERT INTO t_time_good (user_id, amount, created_at, updated_at)
        VALUES (1 + FLOOR(RAND() * 100), ROUND(1 + RAND() * 9999, 2), v_created_dt, v_created_dt);

        SET i = i + 1;

        IF i % 200 = 0 THEN
            COMMIT;
        END IF;
    END WHILE;

    COMMIT;
    SET autocommit = 1;
END $$
DELIMITER ;

CALL sp_seed_time_compare();
DROP PROCEDURE IF EXISTS sp_seed_time_compare;

-- 确认数据量一致
SELECT 't_time_bad'  AS tbl, COUNT(*) AS total_rows FROM t_time_bad
UNION ALL
SELECT 't_time_good', COUNT(*) FROM t_time_good;

-- 在 UTC(+00:00) 会话时区下，两表读出值一致。
-- 切到 +08:00 后再查 bad 表，created_at 会被偏移 +8 小时（见 bad.sql / good.sql）。
-- 预期（以批B的 2026-07-01 20:00:00 UTC 为例）:
--   time_zone=+00:00 时: t_time_bad.created_at = 2026-07-01 20:00:00 (归属 7-1)
--   time_zone=+08:00 时: t_time_bad.created_at = 2026-07-02 04:00:00 (偏移 +8h, 归属 7-2!)
--   任意时区时:        t_time_good.created_at = 2026-07-01 20:00:00 (始终不变, 归属 7-1)
SELECT
    @@session.time_zone AS session_tz,
    (SELECT MIN(created_at) FROM t_time_bad)  AS bad_min_created,
    (SELECT MIN(created_at) FROM t_time_good) AS good_min_created;
