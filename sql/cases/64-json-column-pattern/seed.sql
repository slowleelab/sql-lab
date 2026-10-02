-- ============================================================
-- 造数据: 10 万行商品数据，attrs 随机属性 {"color","size","brand"}
-- ============================================================

DELIMITER $$
DROP PROCEDURE IF EXISTS sp_seed_product_json $$
CREATE PROCEDURE sp_seed_product_json()
BEGIN
    DECLARE i INT DEFAULT 0;
    DECLARE v_name VARCHAR(100);
    DECLARE v_color VARCHAR(20);
    DECLARE v_size VARCHAR(10);
    DECLARE v_brand VARCHAR(20);
    DECLARE v_attrs JSON;
    SET autocommit = 0;

    WHILE i < 100000 DO
        SET v_name  = CONCAT('商品-', LPAD(i, 6, '0'));
        SET v_color = ELT(FLOOR(1 + RAND() * 6), 'red','blue','green','black','white','yellow');
        SET v_size  = ELT(FLOOR(1 + RAND() * 4), 'S','M','L','XL');
        SET v_brand = ELT(FLOOR(1 + RAND() * 5), 'Nike','Adidas','Puma','LiNing','Anta');
        SET v_attrs = JSON_OBJECT('color', v_color, 'size', v_size, 'brand', v_brand);

        INSERT INTO t_product_json (product_name, attrs, created_at)
        VALUES (
            v_name,
            v_attrs,
            NOW() - INTERVAL FLOOR(RAND() * 365) DAY
                 - INTERVAL FLOOR(RAND() * 24) HOUR
        );
        SET i = i + 1;

        IF i % 5000 = 0 THEN
            COMMIT;
        END IF;
    END WHILE;

    -- 确保 color='red' 有足够数据便于对比（约 1/6，约 1.6 万行）
    COMMIT;
    SET autocommit = 1;
END $$
DELIMITER ;

CALL sp_seed_product_json();
DROP PROCEDURE IF EXISTS sp_seed_product_json;

-- 确认数据量 + color 分布
SELECT COUNT(*) AS total_rows FROM t_product_json;
SELECT JSON_UNQUOTE(JSON_EXTRACT(attrs, '$.color')) AS color, COUNT(*) AS cnt
FROM t_product_json
GROUP BY color;
