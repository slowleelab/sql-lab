-- ============================================================
-- 造数据: 10 万用户 + 100 万订单
-- 已支付订单(status=1)约占 20%，且每个 user_id 都存在于用户表
-- ============================================================

DELIMITER $$
DROP PROCEDURE IF EXISTS sp_seed_left_join $$
CREATE PROCEDURE sp_seed_left_join()
BEGIN
    DECLARE i INT DEFAULT 0;
    DECLARE v_status TINYINT;
    SET autocommit = 0;

    -- 1. 用户表: 10 万用户
    WHILE i < 100000 DO
        INSERT INTO t_user (nickname, phone, status, created_at)
        VALUES (
            CONCAT('user_', LPAD(i, 6, '0')),
            CONCAT('138', LPAD(FLOOR(RAND() * 100000000), 8, '0')),
            IF(RAND() < 0.95, 1, 0),                                    -- 95% 正常用户
            NOW() - INTERVAL FLOOR(RAND() * 1095) DAY                   -- 近3年注册
        );
        SET i = i + 1;
        IF i % 5000 = 0 THEN COMMIT; END IF;
    END WHILE;
    COMMIT;

    -- 2. 订单表: 100 万订单，user_id 均匀分布在 1~100000
    --    status 分布: 0待付30% / 1已付20% / 2发货20% / 3完成20% / 4取消10%
    SET i = 0;
    WHILE i < 1000000 DO
        SET v_status = CASE
            WHEN RAND() < 0.30 THEN 0
            WHEN RAND() < 0.625 THEN 1
            WHEN RAND() < 0.875 THEN 2
            WHEN RAND() < 0.95 THEN 3
            ELSE 4
        END;
        INSERT INTO t_order (order_no, user_id, amount, status, created_at)
        VALUES (
            CONCAT('NO', LPAD(i, 10, '0')),
            FLOOR(1 + RAND() * 100000),
            ROUND(1 + RAND() * 9999, 2),
            v_status,
            NOW() - INTERVAL FLOOR(RAND() * 730) DAY
                     - INTERVAL FLOOR(RAND() * 24) HOUR
        );
        SET i = i + 1;
        IF i % 5000 = 0 THEN COMMIT; END IF;
    END WHILE;
    COMMIT;

    SET autocommit = 1;
END $$
DELIMITER ;

CALL sp_seed_left_join();
DROP PROCEDURE IF EXISTS sp_seed_left_join;

-- 确认数据量
SELECT 't_user' AS tbl, COUNT(*) AS rows_count FROM t_user
UNION ALL
SELECT 't_order', COUNT(*) FROM t_order
UNION ALL
SELECT 't_order_paid', COUNT(*) FROM t_order WHERE status = 1;
