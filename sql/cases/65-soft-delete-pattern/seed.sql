-- ============================================================
-- 造数据: 10 万行文档，其中 20% 已软删除（deleted_at 非空）
-- ============================================================

DELIMITER $$
DROP PROCEDURE IF EXISTS sp_seed_document_soft $$
CREATE PROCEDURE sp_seed_document_soft()
BEGIN
    DECLARE i INT DEFAULT 0;
    DECLARE v_deleted DATETIME;
    SET autocommit = 0;

    WHILE i < 100000 DO
        -- 20% 概率软删除: deleted_at 设为某时间，否则 NULL
        IF RAND() < 0.20 THEN
            SET v_deleted = NOW() - INTERVAL FLOOR(RAND() * 180) DAY
                                 - INTERVAL FLOOR(RAND() * 24) HOUR;
        ELSE
            SET v_deleted = NULL;
        END IF;

        INSERT INTO t_document_soft (title, content, author_id, deleted_at, created_at)
        VALUES (
            CONCAT('文档-', LPAD(i, 6, '0')),                              -- 标题
            REPEAT('x', FLOOR(50 + RAND() * 200)),                        -- 内容 50-250 字符
            FLOOR(1 + RAND() * 10000),                                     -- 1万作者
            v_deleted,                                                     -- 软删除时间
            NOW() - INTERVAL FLOOR(RAND() * 730) DAY                       -- 近2年创建
                 - INTERVAL FLOOR(RAND() * 24) HOUR
        );
        SET i = i + 1;

        IF i % 5000 = 0 THEN
            COMMIT;
        END IF;
    END WHILE;

    -- 确保 author_id=12345 有足够未删除数据便于对比查询
    INSERT INTO t_document_soft (title, content, author_id, deleted_at, created_at)
    VALUES
        ('文档-12345-A', REPEAT('a', 100), 12345, NULL, NOW() - INTERVAL 10 DAY),
        ('文档-12345-B', REPEAT('b', 100), 12345, NULL, NOW() - INTERVAL 5 DAY),
        ('文档-12345-C', REPEAT('c', 100), 12345, NULL, NOW() - INTERVAL 2 DAY),
        ('文档-12345-D', REPEAT('d', 100), 12345, NOW() - INTERVAL 1 DAY, NOW() - INTERVAL 30 DAY);
    COMMIT;

    SET autocommit = 1;
END $$
DELIMITER ;

CALL sp_seed_document_soft();
DROP PROCEDURE IF EXISTS sp_seed_document_soft;

-- 确认数据量 + 软删除比例
SELECT COUNT(*) AS total_rows,
       SUM(deleted_at IS NOT NULL) AS deleted_rows,
       SUM(deleted_at IS NULL) AS active_rows
FROM t_document_soft;
