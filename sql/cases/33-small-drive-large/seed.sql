-- ============================================================
-- 造数据: 大表 20 万 + 小表 5000
-- (20万足以展示 JOIN 驱动表差异，避免造数据过慢)
-- ============================================================

DELIMITER $$
DROP PROCEDURE IF EXISTS sp_seed_join $$
CREATE PROCEDURE sp_seed_join()
BEGIN
    DECLARE i INT DEFAULT 0;
    DECLARE v_order_no VARCHAR(32);
    SET autocommit = 0;

    -- 1. 大表: 20 万订单（批量插入，每批 5000 行）
    WHILE i < 200000 DO
        SET v_order_no = CONCAT('NO', LPAD(i, 10, '0'));
        INSERT INTO t_order_big (user_id, order_no, amount, status, created_at)
        VALUES (
            FLOOR(1 + RAND() * 100000),
            v_order_no,
            ROUND(1 + RAND() * 9999, 2),
            FLOOR(RAND() * 4),
            NOW() - INTERVAL FLOOR(RAND() * 730) DAY
        );
        SET i = i + 1;
        IF i % 5000 = 0 THEN COMMIT; END IF;
    END WHILE;
    COMMIT;

    -- 2. 小表: 5000 条活动关联记录，引用大表的 order_no
    SET i = 0;
    WHILE i < 5000 DO
        INSERT INTO t_promotion_ref (promotion_id, order_no, discount)
        VALUES (
            FLOOR(1 + RAND() * 10),
            CONCAT('NO', LPAD(FLOOR(RAND() * 200000), 10, '0')),
            ROUND(RAND() * 500, 2)
        );
        SET i = i + 1;
        IF i % 1000 = 0 THEN COMMIT; END IF;
    END WHILE;
    COMMIT;

    SET autocommit = 1;
END $$
DELIMITER ;

CALL sp_seed_join();
DROP PROCEDURE IF EXISTS sp_seed_join;

SELECT 't_order_big' AS tbl, COUNT(*) AS rows_count FROM t_order_big
UNION ALL
SELECT 't_promotion_ref', COUNT(*) FROM t_promotion_ref;
