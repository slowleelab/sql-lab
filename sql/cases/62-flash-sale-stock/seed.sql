-- ============================================================
-- 造数据: 1000 个商品，每个 stock 随机 10-1000
-- ============================================================

DELIMITER $$
DROP PROCEDURE IF EXISTS sp_seed_stock $$
CREATE PROCEDURE sp_seed_stock()
BEGIN
    DECLARE i INT DEFAULT 0;
    SET autocommit = 0;

    WHILE i < 1000 DO
        INSERT INTO t_stock (product_id, stock, version, updated_at)
        VALUES (
            i + 1,                                              -- 商品ID 1~1000
            FLOOR(10 + RAND() * 991),                           -- 库存 10~1000
            0,                                                  -- 初始版本号
            NOW() - INTERVAL FLOOR(RAND() * 30) DAY             -- 随机更新时间
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

CALL sp_seed_stock();
DROP PROCEDURE IF EXISTS sp_seed_stock;

-- 确认数据量
SELECT COUNT(*) AS total_rows FROM t_stock;
-- 查看 product_id=1 的库存（bad/good 对比用）
SELECT product_id, stock, version FROM t_stock WHERE product_id = 1;
