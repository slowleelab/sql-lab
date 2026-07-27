-- ============================================================
-- 造数据: 10 万行文章数据，content 用 REPEAT 生成较长文本
-- ============================================================

DELIMITER $$
DROP PROCEDURE IF EXISTS sp_seed_article $$
CREATE PROCEDURE sp_seed_article()
BEGIN
    DECLARE i INT DEFAULT 0;
    SET autocommit = 0;

    WHILE i < 100000 DO
        INSERT INTO t_article (title, author, category, content, views, created_at)
        VALUES (
            CONCAT('文章-', LPAD(i, 6, '0')),                              -- 标题
            CONCAT('author', FLOOR(1 + RAND() * 1000)),                   -- 作者
            ELT(FLOOR(1 + RAND() * 5), '技术', '产品', '设计', '运营', '管理'), -- 分类
            REPEAT(CONCAT('这是文章正文内容片段编号', i, '。'), 50),          -- TEXT 正文（约2KB）
            FLOOR(RAND() * 100000),                                        -- 浏览量
            NOW() - INTERVAL FLOOR(RAND() * 365) DAY                       -- 近1年随机时间
                 - INTERVAL FLOOR(RAND() * 24) HOUR
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

CALL sp_seed_article();
DROP PROCEDURE IF EXISTS sp_seed_article;

-- 确认数据量
SELECT COUNT(*) AS total_rows FROM t_article;
