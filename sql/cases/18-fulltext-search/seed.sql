-- ============================================================
-- 造数据: 20 万篇中文文章，每条 content 约 200-500 字
-- 两张表数据完全一致，区别仅在于 good 表有 FULLTEXT 索引
-- ============================================================

DELIMITER $$
DROP PROCEDURE IF EXISTS sp_seed_article_search $$
CREATE PROCEDURE sp_seed_article_search()
BEGIN
    DECLARE i INT DEFAULT 0;
    DECLARE v_title    VARCHAR(200);
    DECLARE v_author   VARCHAR(50);
    DECLARE v_category VARCHAR(20);
    DECLARE v_content  TEXT;
    DECLARE v_created  DATETIME;

    SET autocommit = 0;

    WHILE i < 200000 DO
        -- 标题：从主题模板中选取，确保含可搜索关键词
        SET v_title = ELT(1 + FLOOR(RAND() * 10),
            CONCAT('MySQL性能优化实战指南第', i, '篇'),
            CONCAT('数据库索引设计原理与实战(', i, ')'),
            CONCAT('InnoDB存储引擎深度解析 #', i),
            CONCAT('SQL查询优化技巧总结第', i, '讲'),
            CONCAT('高并发架构设计方案(', i, ')'),
            CONCAT('分布式事务实现原理 #', i),
            CONCAT('Redis缓存策略最佳实践(', i, ')'),
            CONCAT('MySQL主从复制配置详解 #', i),
            CONCAT('慢查询日志分析与调优(', i, ')'),
            CONCAT('分库分表中间件选型指南 #', i)
        );

        -- 作者
        SET v_author = ELT(1 + FLOOR(RAND() * 8),
            CONCAT('技术专家', FLOOR(1 + RAND() * 200)),
            CONCAT('架构师', FLOOR(1 + RAND() * 150)),
            CONCAT('DBA', FLOOR(1 + RAND() * 100)),
            CONCAT('后端工程师', FLOOR(1 + RAND() * 300)),
            CONCAT('数据库管理员', FLOOR(1 + RAND() * 80)),
            CONCAT('资深开发', FLOOR(1 + RAND() * 250)),
            CONCAT('系统工程师', FLOOR(1 + RAND() * 120)),
            CONCAT('研发负责人', FLOOR(1 + RAND() * 90))
        );

        -- 分类
        SET v_category = ELT(1 + FLOOR(RAND() * 5),
            '数据库', '架构', '性能优化', '运维', '开发');

        -- 正文：拼接多段中文内容，约 200-500 字，确保含 "性能优化""索引""数据库" 等关键词
        SET v_content = CONCAT(
            '本文是', v_category, '领域的深度技术文章。MySQL性能优化实战指南是每个后端工程师必修课程。',
            '数据库索引设计原理直接决定了查询效率，合理的索引能让查询从全表扫描变为毫秒级响应。',
            'InnoDB存储引擎采用B+树聚簇索引组织数据，了解其页结构和事务机制对性能调优至关重要。',
            'SQL查询优化技巧总结：避免SELECT星号、减少JOIN表数量、利用覆盖索引、避免函数作用于索引列。',
            '在高并发架构设计方案中，缓存和数据库的协同是关键，Redis缓存策略能显著降低数据库压力。',
            '分布式事务实现原理涉及两阶段提交、TCC、Saga等模式，需根据业务场景选择合适的方案。',
            'MySQL主从复制配置详解包括binlog格式选择、半同步复制、GTID模式等最佳实践。',
            '慢查询日志分析与调优是发现性能瓶颈的第一步，结合EXPLAIN执行计划能精准定位问题。',
            '分库分表中间件选型需考虑数据迁移成本、跨库JOIN、分布式ID生成等实际问题。',
            '性能优化的核心思想是减少IO和计算量，索引是减少IO最有效的手段。', i
        );

        SET v_created = NOW() - INTERVAL FLOOR(RAND() * 730) DAY;

        -- bad 表（无 FULLTEXT）
        INSERT INTO t_article_search_bad (title, author, content, category, created_at)
        VALUES (v_title, v_author, v_content, v_category, v_created);

        -- good 表（有 FULLTEXT + ngram），数据与 bad 表完全一致
        INSERT INTO t_article_search_good (title, author, content, category, created_at)
        VALUES (v_title, v_author, v_content, v_category, v_created);

        SET i = i + 1;

        IF i % 2000 = 0 THEN
            COMMIT;
        END IF;
    END WHILE;

    COMMIT;
    SET autocommit = 1;
END $$
DELIMITER ;

CALL sp_seed_article_search();
DROP PROCEDURE IF EXISTS sp_seed_article_search;

-- 额外插入一批便于对比测试的精确匹配数据（含 "性能优化" 关键词）
INSERT INTO t_article_search_bad (title, author, content, category, created_at) VALUES
    ('性能优化终极手册', '专家A', '本文全面讲解MySQL性能优化实战指南，涵盖索引优化、查询重写、参数调优等核心内容。', '性能优化', NOW()),
    ('数据库性能优化案例', '专家B', '通过真实案例剖析数据库索引设计原理，展示从全表扫描到索引命中的性能优化全过程。', '数据库', NOW()),
    ('性能优化避坑指南', '专家C', '总结性能优化中常见的误区，包括过度索引、缓存雪崩、连接池配置不当等问题。', '性能优化', NOW());

INSERT INTO t_article_search_good (title, author, content, category, created_at) VALUES
    ('性能优化终极手册', '专家A', '本文全面讲解MySQL性能优化实战指南，涵盖索引优化、查询重写、参数调优等核心内容。', '性能优化', NOW()),
    ('数据库性能优化案例', '专家B', '通过真实案例剖析数据库索引设计原理，展示从全表扫描到索引命中的性能优化全过程。', '数据库', NOW()),
    ('性能优化避坑指南', '专家C', '总结性能优化中常见的误区，包括过度索引、缓存雪崩、连接池配置不当等问题。', '性能优化', NOW());

-- 确认数据量一致
SELECT 't_article_search_bad' AS tbl, COUNT(*) AS total_rows FROM t_article_search_bad
UNION ALL
SELECT 't_article_search_good', COUNT(*) FROM t_article_search_good;

-- 查看两张表大小对比（good 表因多 FULLTEXT 索引，index_mb 更大）
SELECT
    TABLE_NAME,
    TABLE_ROWS,
    ROUND(DATA_LENGTH / 1024 / 1024, 2) AS data_mb,
    ROUND(INDEX_LENGTH / 1024 / 1024, 2) AS index_mb,
    ROUND((DATA_LENGTH + INDEX_LENGTH) / 1024 / 1024, 2) AS total_mb
FROM information_schema.TABLES
WHERE TABLE_SCHEMA = DATABASE()
  AND TABLE_NAME IN ('t_article_search_bad', 't_article_search_good');
