-- ============================================================
-- 造数据: 10 万篇文章，正文平均 5KB
-- ============================================================

DELIMITER $$
DROP PROCEDURE IF EXISTS sp_seed_article $$
CREATE PROCEDURE sp_seed_article()
BEGIN
    DECLARE i INT DEFAULT 0;
    DECLARE v_content TEXT;
    SET autocommit = 0;

    WHILE i < 100000 DO
        -- 生成约 5KB 的正文内容
        SET v_content = REPEAT(CONCAT('这是第', i, '篇文章的正文内容段落。'), 100);

        -- bad 表：正文和元数据一起插入
        INSERT INTO t_article_bad (title, author, category, views, content, created_at)
        VALUES (
            CONCAT('文章标题 #', i),
            CONCAT('作者', FLOOR(1 + RAND() * 1000)),
            ELT(1 + FLOOR(RAND() * 5), '技术', '产品', '设计', '运营', '管理'),
            FLOOR(RAND() * 100000),
            v_content,
            NOW() - INTERVAL FLOOR(RAND() * 365) DAY
        );

        -- good 表：主表只插元数据
        INSERT INTO t_article_good (title, author, category, views, created_at)
        VALUES (
            CONCAT('文章标题 #', i),
            CONCAT('作者', FLOOR(1 + RAND() * 1000)),
            ELT(1 + FLOOR(RAND() * 5), '技术', '产品', '设计', '运营', '管理'),
            FLOOR(RAND() * 100000),
            NOW() - INTERVAL FLOOR(RAND() * 365) DAY
        );

        -- good 扩展表：单独存正文
        INSERT INTO t_article_content (article_id, content)
        VALUES (LAST_INSERT_ID(), v_content);

        SET i = i + 1;

        IF i % 2000 = 0 THEN
            COMMIT;
        END IF;
    END WHILE;

    COMMIT;
    SET autocommit = 1;
END $$
DELIMITER ;

CALL sp_seed_article();
DROP PROCEDURE IF EXISTS sp_seed_article;

-- 对比两张表的大小
SELECT
    TABLE_NAME,
    TABLE_ROWS,
    ROUND(DATA_LENGTH / 1024 / 1024, 2) AS data_mb,
    ROUND(INDEX_LENGTH / 1024 / 1024, 2) AS index_mb,
    ROUND((DATA_LENGTH + INDEX_LENGTH) / 1024 / 1024, 2) AS total_mb
FROM information_schema.TABLES
WHERE TABLE_SCHEMA = DATABASE()
  AND TABLE_NAME IN ('t_article_bad', 't_article_good', 't_article_content');
