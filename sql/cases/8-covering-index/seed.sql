-- ============================================================
-- 造数据: 30 万商品数据
-- ============================================================

DELIMITER $$
DROP PROCEDURE IF EXISTS sp_seed_product $$
CREATE PROCEDURE sp_seed_product()
BEGIN
    DECLARE i INT DEFAULT 0;
    SET autocommit = 0;

    WHILE i < 300000 DO
        INSERT INTO t_product (name, category_id, price, stock, description, status, created_at)
        VALUES (
            CONCAT('商品_', LPAD(i, 6, '0')),
            FLOOR(1 + RAND() * 100),
            ROUND(1 + RAND() * 9999, 2),
            FLOOR(RAND() * 10000),
            REPEAT('这是一段商品描述文本。', 20),
            IF(RAND() > 0.1, 1, 0),
            NOW() - INTERVAL FLOOR(RAND() * 730) DAY
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

CALL sp_seed_product();
DROP PROCEDURE IF EXISTS sp_seed_product;

SELECT COUNT(*) AS total_rows FROM t_product;
