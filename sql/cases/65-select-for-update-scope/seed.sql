-- ============================================================
-- 造数据: 10 万商品数据，category 分布在几个分类上（无索引）
-- ============================================================

DELIMITER $$
DROP PROCEDURE IF EXISTS sp_seed_product $$
CREATE PROCEDURE sp_seed_product()
BEGIN
    DECLARE i INT DEFAULT 0;
    DECLARE v_cate VARCHAR(20);

    SET autocommit = 0;

    WHILE i < 100000 DO
        SET v_cate = ELT(FLOOR(1 + RAND() * 5), '电子', '服装', '食品', '家居', '图书');

        INSERT INTO t_product (product_name, stock, category, price, updated_at)
        VALUES (
            CONCAT('商品-', LPAD(i + 1, 6, '0')),                          -- 商品-000001
            FLOOR(RAND() * 5000),                                          -- 库存 0~4999
            v_cate,                                                        -- 分类
            ROUND(10 + RAND() * 9990, 2),                                 -- 价格 10~10000
            NOW() - INTERVAL FLOOR(RAND() * 365) DAY
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

-- 确认数据量
SELECT COUNT(*) AS total_rows FROM t_product;
-- 查看各分类数据分布
SELECT category, COUNT(*) AS cnt FROM t_product GROUP BY category;
