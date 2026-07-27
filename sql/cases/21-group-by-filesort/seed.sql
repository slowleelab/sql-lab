-- ============================================================
-- 造数据: 50 万订单统计数据
-- ============================================================

DELIMITER $$
DROP PROCEDURE IF EXISTS sp_seed_order_stat $$
CREATE PROCEDURE sp_seed_order_stat()
BEGIN
    DECLARE i INT DEFAULT 0;
    DECLARE v_city VARCHAR(20);
    DECLARE v_cate VARCHAR(20);

    SET autocommit = 0;

    WHILE i < 500000 DO
        SET v_city = ELT(FLOOR(1 + RAND() * 8), '北京','上海','广州','深圳','杭州','成都','武汉','西安');
        SET v_cate = ELT(FLOOR(1 + RAND() * 6), '电子','服装','食品','家居','图书','运动');

        INSERT INTO t_order_stat (user_id, city, product_cate, amount, order_date)
        VALUES (
            FLOOR(1 + RAND() * 50000),
            v_city,
            v_cate,
            ROUND(1 + RAND() * 9999, 2),
            CURDATE() - INTERVAL FLOOR(RAND() * 365) DAY
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

CALL sp_seed_order_stat();
DROP PROCEDURE IF EXISTS sp_seed_order_stat;

SELECT COUNT(*) AS total_rows FROM t_order_stat;
