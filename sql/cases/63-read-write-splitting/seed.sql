-- ============================================================
-- 造数据: 主库表与从库表各填 10 万行相同数据（模拟主从复制同步）
-- ============================================================

DELIMITER $$
DROP PROCEDURE IF EXISTS sp_seed_rw_split $$
CREATE PROCEDURE sp_seed_rw_split()
BEGIN
    DECLARE i INT DEFAULT 0;
    DECLARE v_uid BIGINT;
    DECLARE v_no VARCHAR(32);
    DECLARE v_amt DECIMAL(10,2);
    DECLARE v_status TINYINT;
    DECLARE v_ts DATETIME;
    SET autocommit = 0;

    -- 1. 主库表: 10 万行
    WHILE i < 100000 DO
        SET v_uid    = FLOOR(1 + RAND() * 100000);                         -- 10万用户
        SET v_no     = CONCAT('NO', LPAD(i, 10, '0'));                     -- 唯一订单号
        SET v_amt    = ROUND(1 + RAND() * 9999, 2);                        -- 金额
        SET v_status = FLOOR(RAND() * 4);                                  -- 状态
        SET v_ts     = NOW() - INTERVAL FLOOR(RAND() * 365) DAY
                              - INTERVAL FLOOR(RAND() * 24) HOUR;          -- 近1年

        INSERT INTO t_order_master (user_id, order_no, amount, status, created_at)
        VALUES (v_uid, v_no, v_amt, v_status, v_ts);
        SET i = i + 1;

        IF i % 5000 = 0 THEN
            COMMIT;
        END IF;
    END WHILE;
    COMMIT;

    -- 2. 从库表: 复制主库数据，模拟主从同步后的从库读节点
    INSERT INTO t_order_replica (id, user_id, order_no, amount, status, created_at)
    SELECT id, user_id, order_no, amount, status, created_at FROM t_order_master;
    COMMIT;

    -- 3. 确保 user_id=12345 在两表都有数据，便于对比查询
    INSERT INTO t_order_master (user_id, order_no, amount, status, created_at)
    VALUES (12345, 'NO_RW_12345_01', 199.00, 1, NOW() - INTERVAL 5 DAY);
    INSERT INTO t_order_master (user_id, order_no, amount, status, created_at)
    VALUES (12345, 'NO_RW_12345_02', 88.00, 0, NOW() - INTERVAL 2 DAY);
    COMMIT;

    INSERT INTO t_order_replica (id, user_id, order_no, amount, status, created_at)
    SELECT id, user_id, order_no, amount, status, created_at
    FROM t_order_master
    WHERE user_id = 12345 AND order_no IN ('NO_RW_12345_01','NO_RW_12345_02');
    COMMIT;

    SET autocommit = 1;
END $$
DELIMITER ;

CALL sp_seed_rw_split();
DROP PROCEDURE IF EXISTS sp_seed_rw_split;

-- 确认数据量（两表应一致，模拟主从同步完成）
SELECT 't_order_master' AS tbl, COUNT(*) AS rows_count FROM t_order_master
UNION ALL
SELECT 't_order_replica', COUNT(*) FROM t_order_replica;
