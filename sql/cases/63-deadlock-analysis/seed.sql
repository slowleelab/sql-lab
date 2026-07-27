-- ============================================================
-- 造数据: 10 万订单数据，order_no 格式 NO000001 ~ NO100000
-- ============================================================

DELIMITER $$
DROP PROCEDURE IF EXISTS sp_seed_order_deadlock $$
CREATE PROCEDURE sp_seed_order_deadlock()
BEGIN
    DECLARE i INT DEFAULT 0;

    SET autocommit = 0;

    WHILE i < 100000 DO
        INSERT INTO t_order_deadlock (order_no, amount, status, version, updated_at)
        VALUES (
            CONCAT('NO', LPAD(i + 1, 6, '0')),                       -- NO000001 ~ NO100000
            ROUND(10 + RAND() * 9990, 2),                            -- 金额 10~10000
            ELT(FLOOR(1 + RAND() * 4), 'NEW', 'PAID', 'SHIPPED', 'DONE'),
            0,
            NOW() - INTERVAL FLOOR(RAND() * 90) DAY
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

CALL sp_seed_order_deadlock();
DROP PROCEDURE IF EXISTS sp_seed_order_deadlock;

-- 确认数据量
SELECT COUNT(*) AS total_rows FROM t_order_deadlock;
-- 查看两条用于死锁演示的订单
SELECT id, order_no, amount, status FROM t_order_deadlock WHERE id IN (1, 2);
