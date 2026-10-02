-- ============================================================
-- 造数据: 100 万行订单数据
-- user_id 在 1~100000 范围内，每个用户约 10 条订单
-- ============================================================

DELIMITER $$
DROP PROCEDURE IF EXISTS sp_seed_order $$
CREATE PROCEDURE sp_seed_order()
BEGIN
    DECLARE i INT DEFAULT 0;
    SET autocommit = 0;

    WHILE i < 1000000 DO
        INSERT INTO t_order (order_no, user_id, amount, status, created_at)
        VALUES (
            CONCAT('NO', LPAD(i + 1, 10, '0')),                         -- 订单号
            FLOOR(1 + RAND() * 100000),                                  -- 10万用户
            ROUND(1 + RAND() * 9999, 2),                                 -- 金额 1~10000
            FLOOR(RAND() * 4),                                           -- 状态 0~3
            NOW() - INTERVAL FLOOR(RAND() * 730) DAY
                     - INTERVAL FLOOR(RAND() * 24) HOUR
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
-- 查看 user_id=100 的订单数
SELECT COUNT(*) AS user_100_orders FROM t_order WHERE user_id = 100;
-- 查看分组数（不同 user_id 数量）
SELECT COUNT(DISTINCT user_id) AS distinct_users FROM t_order;
