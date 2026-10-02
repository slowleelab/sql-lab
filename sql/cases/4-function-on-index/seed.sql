-- ============================================================
-- 造数据: 30 万行订单数据
-- ============================================================

DELIMITER $$
DROP PROCEDURE IF EXISTS sp_seed_order_func $$
CREATE PROCEDURE sp_seed_order_func()
BEGIN
    DECLARE i INT DEFAULT 0;
    SET autocommit = 0;

    WHILE i < 300000 DO
        INSERT INTO t_order_func (user_id, order_no, amount, created_at)
        VALUES (
            FLOOR(1 + RAND() * 100000),                              -- 10万用户
            CONCAT('NO', LPAD(i, 10, '0')),                           -- 订单号
            ROUND(1 + RAND() * 9999, 2),                              -- 金额 1~10000
            NOW() - INTERVAL FLOOR(RAND() * 730) DAY                  -- 近2年随机时间
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

CALL sp_seed_order_func();
DROP PROCEDURE IF EXISTS sp_seed_order_func;

-- 插入固定日期数据，便于 bad/good 对比测试
INSERT INTO t_order_func (user_id, order_no, amount, created_at)
VALUES
    (99901, 'NO_FUNC_0001', 199.00, '2026-07-01 08:00:00'),
    (99902, 'NO_FUNC_0002', 299.00, '2026-07-01 12:30:00'),
    (99903, 'NO_FUNC_0003', 88.00,  '2026-07-01 23:59:59');

-- 确认数据量
SELECT COUNT(*) AS total_rows FROM t_order_func;
