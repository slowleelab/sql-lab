-- ============================================================
-- 造数据: 100 万行订单数据
-- status 分布: 0(20%) 1(30%) 2(40%) 3(10%)
-- 其中 status=2 且 created_at < '2026-01-01' 的约 50 万行（用于分批更新演示）
-- ============================================================

DELIMITER $$
DROP PROCEDURE IF EXISTS sp_seed_order $$
CREATE PROCEDURE sp_seed_order()
BEGIN
    DECLARE i INT DEFAULT 0;
    DECLARE v_status TINYINT;
    DECLARE v_created DATETIME;
    SET autocommit = 0;

    WHILE i < 1000000 DO
        -- status 分布: 0(20%) 1(30%) 2(40%) 3(10%)
        SET v_status = CASE
            WHEN RAND() < 0.20 THEN 0
            WHEN RAND() < 0.50 THEN 1
            WHEN RAND() < 0.90 THEN 2
            ELSE 3
        END;

        -- created_at: 50% 在 2026-01-01 之前，50% 在之后
        IF RAND() < 0.5 THEN
            SET v_created = NOW() - INTERVAL FLOOR(RAND() * 365) DAY
                                   - INTERVAL FLOOR(RAND() * 24) HOUR;
        ELSE
            SET v_created = NOW() + INTERVAL FLOOR(RAND() * 365) DAY
                                   + INTERVAL FLOOR(RAND() * 24) HOUR;
        END IF;

        INSERT INTO t_order (order_no, user_id, amount, status, created_at)
        VALUES (
            CONCAT('NO', LPAD(i + 1, 10, '0')),                         -- 订单号
            FLOOR(1 + RAND() * 100000),                                  -- 10万用户
            ROUND(1 + RAND() * 9999, 2),                                 -- 金额 1~10000
            v_status,
            v_created
        );
        SET i = i + 1;

        IF i % 5000 = 0 THEN
            COMMIT;
        END IF;
    END WHILE;

    COMMIT;
    SET autocommit = 1;
END $$
DELIMITER ;

CALL sp_seed_order();
DROP PROCEDURE IF EXISTS sp_seed_order;

-- 确认数据量
SELECT COUNT(*) AS total_rows FROM t_order;
-- 查看需要更新的行数（status=2 且 created_at < '2026-01-01'）
SELECT COUNT(*) AS rows_to_update FROM t_order WHERE status = 2 AND created_at < '2026-01-01';
