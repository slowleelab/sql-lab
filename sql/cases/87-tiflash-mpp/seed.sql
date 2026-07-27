DELIMITER $$
DROP PROCEDURE IF EXISTS sp_seed_sales $$
CREATE PROCEDURE sp_seed_sales()
BEGIN
    DECLARE i INT DEFAULT 0;
    SET autocommit = 0;
    WHILE i < 500000 DO
        INSERT INTO t_sales (product_id, category, region, amount, qty, sale_date)
        VALUES (
            FLOOR(1 + RAND() * 10000),
            CASE i % 6
                WHEN 0 THEN '电子产品'
                WHEN 1 THEN '服装鞋帽'
                WHEN 2 THEN '食品饮料'
                WHEN 3 THEN '家居用品'
                WHEN 4 THEN '图书音像'
                ELSE '运动户外'
            END,
            CASE i % 10
                WHEN 0 THEN '华北'
                WHEN 1 THEN '华东'
                WHEN 2 THEN '华南'
                WHEN 3 THEN '华中'
                WHEN 4 THEN '东北'
                WHEN 5 THEN '西南'
                WHEN 6 THEN '西北'
                WHEN 7 THEN '港澳台'
                WHEN 8 THEN '北京'
                ELSE '上海'
            END,
            ROUND(10 + RAND() * 9990, 2),
            FLOOR(1 + RAND() * 100),
            DATE_ADD('2025-07-01', INTERVAL FLOOR(RAND() * 365) DAY)
        );
        SET i = i + 1;
        IF i % 5000 = 0 THEN COMMIT; END IF;
    END WHILE;
    COMMIT;
    SET autocommit = 1;
END $$
DELIMITER ;

CALL sp_seed_sales();
DROP PROCEDURE IF EXISTS sp_seed_sales;

SELECT COUNT(*) AS sales_rows FROM t_sales;
