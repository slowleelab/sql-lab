-- ============================================================
-- 造数据: 100 万用户 + 布隆过滤器哈希表
-- ============================================================

DELIMITER $$
DROP PROCEDURE IF EXISTS sp_seed_bloom $$
CREATE PROCEDURE sp_seed_bloom()
BEGIN
    DECLARE i INT DEFAULT 0;
    SET autocommit = 0;

    -- 1. 用户表: 100 万用户
    WHILE i < 1000000 DO
        INSERT INTO t_user (nickname, phone, email, status, created_at)
        VALUES (
            CONCAT('user_', LPAD(i, 7, '0')),
            CONCAT('1', FLOOR(3 + RAND() * 5), LPAD(FLOOR(RAND() * 1000000000), 9, '0')),
            CONCAT('user', i, '@example.com'),
            IF(RAND() < 0.95, 1, 0),
            NOW() - INTERVAL FLOOR(RAND() * 1095) DAY
        );
        SET i = i + 1;
        IF i % 5000 = 0 THEN COMMIT; END IF;
    END WHILE;
    COMMIT;

    -- 2. 布隆过滤器: 将所有存在的用户 ID 的哈希值写入
    --    实际布隆过滤器在内存中用位数组，这里用表模拟
    INSERT INTO t_bloom_filter (user_id_hash)
    SELECT id FROM t_user;
    COMMIT;

    SET autocommit = 1;
END $$
DELIMITER ;

CALL sp_seed_bloom();
DROP PROCEDURE IF EXISTS sp_seed_bloom;

-- 确认数据量
SELECT 't_user' AS tbl, COUNT(*) AS rows_count FROM t_user
UNION ALL
SELECT 't_bloom_filter', COUNT(*) FROM t_bloom_filter;
