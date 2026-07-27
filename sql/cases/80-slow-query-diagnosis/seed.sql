-- ============================================================
-- 造数据: 50 万行订单数据
-- 数据特征:
--   user_id   在 1~100000 范围内（10万用户，每用户约 5 单）
--   status    0~3 随机分布（各约 25%）
--   created_at 近 2 年随机时间
-- 选用 50 万行而非 100 万：足以让慢查询明显，又控制造数据耗时
-- ============================================================

DELIMITER $$
DROP PROCEDURE IF EXISTS sp_seed_order_diag $$
CREATE PROCEDURE sp_seed_order_diag()
BEGIN
    DECLARE i INT DEFAULT 0;
    SET autocommit = 0;

    WHILE i < 500000 DO
        INSERT INTO t_order_diag (order_no, user_id, amount, status, created_at)
        VALUES (
            CONCAT('NO', LPAD(i + 1, 9, '0')),                             -- 订单号
            FLOOR(1 + RAND() * 100000),                                    -- 10万用户
            ROUND(1 + RAND() * 9999, 2),                                   -- 金额 1~10000
            FLOOR(RAND() * 4),                                             -- status 0~3 随机
            NOW() - INTERVAL FLOOR(RAND() * 730) DAY                       -- 近2年随机
                 - INTERVAL FLOOR(RAND() * 24) HOUR
                 - INTERVAL FLOOR(RAND() * 60) MINUTE
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

CALL sp_seed_order_diag();
DROP PROCEDURE IF EXISTS sp_seed_order_diag;

-- 确认数据量
SELECT COUNT(*) AS total_rows FROM t_order_diag;
-- 查看 status 分布（各约 25%）
SELECT status, COUNT(*) AS cnt, ROUND(COUNT(*)*100/500000, 2) AS pct
FROM t_order_diag
GROUP BY status
ORDER BY status;
-- 查看 user_id=12345 的订单数（用于 SQL 2 的 EXPLAIN rows 参考）
SELECT COUNT(*) AS user_12345_orders FROM t_order_diag WHERE user_id = 12345;
