-- ============================================================
-- 造数据: t_order_sj 10 万行 + t_order_item_sj 30 万行 + t_product_sj 1 万行
-- ============================================================

DELIMITER $$
DROP PROCEDURE IF EXISTS sp_seed_straight_join $$
CREATE PROCEDURE sp_seed_straight_join()
BEGIN
    DECLARE i INT DEFAULT 0;
    DECLARE v_category VARCHAR(20);

    SET autocommit = 0;

    -- 1. 商品表: 1 万行，category 有 10 个分类
    WHILE i < 10000 DO
        SET v_category = ELT(FLOOR(1 + RAND() * 10),
            '电子','服装','食品','家居','图书','运动','美妆','母婴','汽车','宠物');

        INSERT INTO t_product_sj (name, category, price, created_at)
        VALUES (
            CONCAT('商品_', LPAD(i, 5, '0')),
            v_category,
            ROUND(1 + RAND() * 9999, 2),
            NOW() - INTERVAL FLOOR(RAND() * 730) DAY
        );
        SET i = i + 1;
        IF i % 1000 = 0 THEN COMMIT; END IF;
    END WHILE;
    COMMIT;

    -- 2. 订单表: 10 万行，user_id 引用 1~50000
    SET i = 0;
    WHILE i < 100000 DO
        INSERT INTO t_order_sj (user_id, order_no, amount, status, created_at)
        VALUES (
            FLOOR(1 + RAND() * 50000),
            CONCAT('NO', LPAD(i, 10, '0')),
            ROUND(1 + RAND() * 9999, 2),
            FLOOR(RAND() * 4),
            NOW() - INTERVAL FLOOR(RAND() * 365) DAY
        );
        SET i = i + 1;
        IF i % 5000 = 0 THEN COMMIT; END IF;
    END WHILE;
    COMMIT;

    -- 3. 订单项表: 30 万行，order_id 引用 1~100000，product_id 引用 1~10000
    SET i = 0;
    WHILE i < 300000 DO
        INSERT INTO t_order_item_sj (order_id, product_id, quantity, price)
        VALUES (
            FLOOR(1 + RAND() * 100000),
            FLOOR(1 + RAND() * 10000),
            FLOOR(1 + RAND() * 10),
            ROUND(1 + RAND() * 999, 2)
        );
        SET i = i + 1;
        IF i % 5000 = 0 THEN COMMIT; END IF;
    END WHILE;
    COMMIT;

    SET autocommit = 1;
END $$
DELIMITER ;

CALL sp_seed_straight_join();
DROP PROCEDURE IF EXISTS sp_seed_straight_join;

-- 确认数据量
SELECT 't_order_sj' AS tbl, COUNT(*) AS rows_count FROM t_order_sj
UNION ALL
SELECT 't_order_item_sj', COUNT(*) FROM t_order_item_sj
UNION ALL
SELECT 't_product_sj', COUNT(*) FROM t_product_sj;
