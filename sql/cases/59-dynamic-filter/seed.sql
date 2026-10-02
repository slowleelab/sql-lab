-- ============================================================
-- 造数据: 20 万行商品数据
-- ============================================================

DELIMITER $$
DROP PROCEDURE IF EXISTS sp_seed_goods $$
CREATE PROCEDURE sp_seed_goods()
BEGIN
    DECLARE i INT DEFAULT 0;
    SET autocommit = 0;

    WHILE i < 200000 DO
        INSERT INTO t_goods (name, category_id, brand_id, price, status, sales, created_at)
        VALUES (
            CONCAT('商品-', LPAD(i, 6, '0')),                               -- 商品名称
            FLOOR(1 + RAND() * 50),                                         -- 50个分类
            FLOOR(1 + RAND() * 200),                                        -- 200个品牌
            ROUND(1 + RAND() * 9999, 2),                                    -- 价格 1~10000
            ELT(FLOOR(1 + RAND() * 3), 1, 1, 2),                            -- 60%在售 20%下架 20%缺货
            FLOOR(RAND() * 50000),                                          -- 销量
            NOW() - INTERVAL FLOOR(RAND() * 365) DAY                        -- 近1年
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

CALL sp_seed_goods();
DROP PROCEDURE IF EXISTS sp_seed_goods;

-- 确认数据量
SELECT COUNT(*) AS total_rows FROM t_goods;
