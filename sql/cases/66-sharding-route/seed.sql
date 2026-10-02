-- ============================================================
-- 造数据: 4 个分片各 25 万行（共 100 万行）
-- 按 user_id % 4 路由到对应分片
-- ============================================================

DELIMITER $$
DROP PROCEDURE IF EXISTS sp_seed_sharding $$
CREATE PROCEDURE sp_seed_sharding()
BEGIN
    DECLARE i INT DEFAULT 0;
    DECLARE v_uid BIGINT;
    DECLARE v_shard INT;
    SET autocommit = 0;

    WHILE i < 1000000 DO
        SET v_uid = FLOOR(1 + RAND() * 100000);          -- 10万用户
        SET v_shard = v_uid % 4;                          -- 路由计算

        -- 按路由结果插入对应分片
        IF v_shard = 0 THEN
            INSERT INTO t_order_0 (order_no, user_id, amount, status, created_at)
            VALUES (CONCAT('NO', LPAD(i, 10, '0')), v_uid,
                    ROUND(1 + RAND() * 9999, 2), FLOOR(RAND() * 4),
                    NOW() - INTERVAL FLOOR(RAND() * 730) DAY);
        ELSEIF v_shard = 1 THEN
            INSERT INTO t_order_1 (order_no, user_id, amount, status, created_at)
            VALUES (CONCAT('NO', LPAD(i, 10, '0')), v_uid,
                    ROUND(1 + RAND() * 9999, 2), FLOOR(RAND() * 4),
                    NOW() - INTERVAL FLOOR(RAND() * 730) DAY);
        ELSEIF v_shard = 2 THEN
            INSERT INTO t_order_2 (order_no, user_id, amount, status, created_at)
            VALUES (CONCAT('NO', LPAD(i, 10, '0')), v_uid,
                    ROUND(1 + RAND() * 9999, 2), FLOOR(RAND() * 4),
                    NOW() - INTERVAL FLOOR(RAND() * 730) DAY);
        ELSE
            INSERT INTO t_order_3 (order_no, user_id, amount, status, created_at)
            VALUES (CONCAT('NO', LPAD(i, 10, '0')), v_uid,
                    ROUND(1 + RAND() * 9999, 2), FLOOR(RAND() * 4),
                    NOW() - INTERVAL FLOOR(RAND() * 730) DAY);
        END IF;

        SET i = i + 1;
        IF i % 5000 = 0 THEN COMMIT; END IF;
    END WHILE;

    COMMIT;

    -- 确保 user_id=100 在分片 0 有数据（100 % 4 = 0）
    INSERT INTO t_order_0 (order_no, user_id, amount, status, created_at)
    VALUES ('NO_ROUTE_100_01', 100, 199.00, 1, NOW() - INTERVAL 5 DAY);
    INSERT INTO t_order_0 (order_no, user_id, amount, status, created_at)
    VALUES ('NO_ROUTE_100_02', 100, 88.00, 0, NOW() - INTERVAL 2 DAY);
    COMMIT;

    SET autocommit = 1;
END $$
DELIMITER ;

CALL sp_seed_sharding();
DROP PROCEDURE IF EXISTS sp_seed_sharding;

-- 确认各分片数据量
SELECT 't_order_0' AS tbl, COUNT(*) AS rows_count FROM t_order_0
UNION ALL
SELECT 't_order_1', COUNT(*) FROM t_order_1
UNION ALL
SELECT 't_order_2', COUNT(*) FROM t_order_2
UNION ALL
SELECT 't_order_3', COUNT(*) FROM t_order_3;
