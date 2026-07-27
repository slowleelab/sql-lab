-- ============================================================
-- 造数据: 100 万行资讯流数据
-- ============================================================

DELIMITER $$
DROP PROCEDURE IF EXISTS sp_seed_feed $$
CREATE PROCEDURE sp_seed_feed()
BEGIN
    DECLARE i INT DEFAULT 0;
    SET autocommit = 0;

    WHILE i < 1000000 DO
        INSERT INTO t_feed (user_id, content, status, created_at)
        VALUES (
            FLOOR(1 + RAND() * 100000),                              -- 10万用户
            CONCAT('动态内容 #', i),                                  -- 内容
            ELT(1 + FLOOR(RAND() * 3), 1, 1, 2),                     -- 大部分已发布
            NOW() - INTERVAL FLOOR(RAND() * 730) DAY                  -- 近2年随机时间
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

CALL sp_seed_feed();
DROP PROCEDURE IF EXISTS sp_seed_feed;

-- 确认数据量
SELECT COUNT(*) AS total_rows FROM t_feed;
