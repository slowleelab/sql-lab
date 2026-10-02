-- ============================================================
-- 造数据: 插入 20 万行后 DELETE 70% 数据，产生碎片
-- ============================================================

DELIMITER $$
DROP PROCEDURE IF EXISTS sp_seed_fragment $$
CREATE PROCEDURE sp_seed_fragment()
BEGIN
    DECLARE i INT DEFAULT 0;
    SET autocommit = 0;

    -- 1. 插入 20 万行订单
    WHILE i < 200000 DO
        INSERT INTO t_fragment_order (user_id, order_no, amount, status, created_at)
        VALUES (
            FLOOR(1 + RAND() * 10000),                               -- 1万用户
            CONCAT('NO', LPAD(i, 10, '0')),                          -- 订单号
            ROUND(1 + RAND() * 9999, 2),                             -- 金额 1~10000
            FLOOR(RAND() * 5),                                       -- 状态 0~4
            NOW() - INTERVAL FLOOR(RAND() * 730) DAY
                 - INTERVAL FLOOR(RAND() * 24) HOUR
        );
        SET i = i + 1;

        IF i % 5000 = 0 THEN
            COMMIT;
        END IF;
    END WHILE;
    COMMIT;

    -- 2. DELETE 70% 数据（保留 status=1 已付款和 status=3 已完成的订单）
    -- 被删除的行留下"空洞"，InnoDB 不会自动回收物理空间给操作系统
    DELETE FROM t_fragment_order WHERE status IN (0, 2, 4);
    COMMIT;

    SET autocommit = 1;
END $$
DELIMITER ;

CALL sp_seed_fragment();
DROP PROCEDURE IF EXISTS sp_seed_fragment;

-- 确认数据量
SELECT COUNT(*) AS remaining_rows FROM t_fragment_order;

-- 查看碎片情况（DELETE 后，DATA_FREE 会较大）
SELECT
    table_name,
    table_rows,
    ROUND(data_length / 1024 / 1024, 2)  AS data_mb,
    ROUND(index_length / 1024 / 1024, 2) AS index_mb,
    ROUND(data_free / 1024 / 1024, 2)    AS free_mb
FROM information_schema.tables
WHERE table_schema = DATABASE() AND table_name = 't_fragment_order';
