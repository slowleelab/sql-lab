-- ============================================================
-- 造数据: t_order_main 10万行 + t_order_item 30万行
-- ============================================================

DELIMITER $$
DROP PROCEDURE IF EXISTS sp_seed_driven $$
CREATE PROCEDURE sp_seed_driven()
BEGIN
    DECLARE i INT DEFAULT 0;
    SET autocommit = 0;

    -- 1. 订单主表: 10 万行
    WHILE i < 100000 DO
        INSERT INTO t_order_main (user_id, order_no, amount)
        VALUES (
            FLOOR(1 + RAND() * 10000),
            CONCAT('NO', LPAD(i, 10, '0')),
            ROUND(1 + RAND() * 9999, 2)
        );
        SET i = i + 1;
        IF i % 5000 = 0 THEN COMMIT; END IF;
    END WHILE;
    COMMIT;

    -- 2. 订单明细表: 30 万行，每单 1~3 条明细，order_id 引用主表
    SET i = 0;
    WHILE i < 300000 DO
        INSERT INTO t_order_item (order_id, product_name, qty)
        VALUES (
            FLOOR(1 + RAND() * 100000),
            CONCAT('商品_', LPAD(FLOOR(RAND() * 1000), 4, '0')),
            FLOOR(1 + RAND() * 10)
        );
        SET i = i + 1;
        IF i % 5000 = 0 THEN COMMIT; END IF;
    END WHILE;
    COMMIT;

    SET autocommit = 1;
END $$
DELIMITER ;

CALL sp_seed_driven();
DROP PROCEDURE IF EXISTS sp_seed_driven;

SELECT 't_order_main' AS tbl, COUNT(*) AS rows_count FROM t_order_main
UNION ALL
SELECT 't_order_item', COUNT(*) FROM t_order_item;
