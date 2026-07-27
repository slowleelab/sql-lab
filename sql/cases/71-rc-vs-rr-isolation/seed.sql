-- ============================================================
-- 造数据: 50 万行订单数据
-- user_id 在 1~50000 范围内，每个用户约 10 条订单
-- status 分布: 0(30%) 1(40%) 2(20%) 3(10%)
-- ============================================================

DELIMITER $$
DROP PROCEDURE IF EXISTS sp_seed_order $$
CREATE PROCEDURE sp_seed_order()
BEGIN
    DECLARE i INT DEFAULT 0;
    DECLARE v_status TINYINT;
    SET autocommit = 0;

    WHILE i < 500000 DO
        -- status 分布: 0(30%) 1(40%) 2(20%) 3(10%)
        SET v_status = CASE
            WHEN RAND() < 0.30 THEN 0
            WHEN RAND() < 0.70 THEN 1
            WHEN RAND() < 0.90 THEN 2
            ELSE 3
        END;

        INSERT INTO t_order (order_no, user_id, amount, status, created_at)
        VALUES (
            CONCAT('NO', LPAD(i + 1, 10, '0')),                         -- 订单号
            FLOOR(1 + RAND() * 50000),                                   -- 5万用户
            ROUND(1 + RAND() * 9999, 2),                                 -- 金额 1~10000
            v_status,
            NOW() - INTERVAL FLOOR(RAND() * 365) DAY
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
-- 查看 user_id=100 的订单分布（用于演示）
SELECT status, COUNT(*) AS cnt FROM t_order WHERE user_id = 100 GROUP BY status ORDER BY status;
