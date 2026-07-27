-- ============================================================
-- 造数据: 5 万个商品库存记录，stock 随机 100~5000，version=0
-- ============================================================

DELIMITER $$
DROP PROCEDURE IF EXISTS sp_seed_stock_lock $$
CREATE PROCEDURE sp_seed_stock_lock()
BEGIN
    DECLARE i INT DEFAULT 0;

    SET autocommit = 0;

    WHILE i < 50000 DO
        INSERT INTO t_stock_lock (product_id, stock, version, updated_at)
        VALUES (
            i + 1,                                              -- 商品ID 1~50000
            FLOOR(100 + RAND() * 4900),                         -- 库存 100~5000
            0,                                                  -- 初始版本号
            NOW() - INTERVAL FLOOR(RAND() * 30) DAY
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

CALL sp_seed_stock_lock();
DROP PROCEDURE IF EXISTS sp_seed_stock_lock;

-- 确认数据量
SELECT COUNT(*) AS total_rows FROM t_stock_lock;
-- 查看商品1的库存与版本（用于 bad/good 对比）
SELECT id, product_id, stock, version FROM t_stock_lock WHERE product_id = 1;
