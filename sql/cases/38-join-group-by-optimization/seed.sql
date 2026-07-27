-- ============================================================
-- 造数据: 订单表 100 万行 + 用户表 1 万行(10个地区)
-- ============================================================

DELIMITER $$
DROP PROCEDURE IF EXISTS sp_seed_order_user $$
CREATE PROCEDURE sp_seed_order_user()
BEGIN
    DECLARE i INT DEFAULT 0;
    DECLARE v_region VARCHAR(20);
    SET autocommit = 0;

    -- 1. 用户表: 1 万行，分布在 10 个地区
    WHILE i < 10000 DO
        SET v_region = ELT(1 + FLOOR(RAND() * 10),
            '华北','华东','华南','华中','西南',
            '西北','东北','海外','港澳台','其他');
        INSERT INTO t_user (user_name, region, created_at)
        VALUES (
            CONCAT('user_', LPAD(i, 5, '0')),
            v_region,
            NOW() - INTERVAL FLOOR(RAND() * 1095) DAY
        );
        SET i = i + 1;
        IF i % 5000 = 0 THEN COMMIT; END IF;
    END WHILE;
    COMMIT;

    -- 2. 订单表: 100 万行，user_id 指向 1 万用户
    SET i = 0;
    WHILE i < 1000000 DO
        INSERT INTO t_order (user_id, order_no, amount, status, created_at)
        VALUES (
            FLOOR(1 + RAND() * 10000),                              -- 1万用户
            CONCAT('NO', LPAD(i, 10, '0')),                         -- 订单号
            ROUND(1 + RAND() * 9999, 2),                            -- 金额 1~10000
            FLOOR(RAND() * 4),                                      -- 状态 0~3
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

CALL sp_seed_order_user();
DROP PROCEDURE IF EXISTS sp_seed_order_user;

-- 确认数据量
SELECT 't_order' AS tbl, COUNT(*) AS rows_count FROM t_order
UNION ALL
SELECT 't_user', COUNT(*) FROM t_user;
SELECT region, COUNT(*) AS user_cnt FROM t_user GROUP BY region ORDER BY region;
