-- 种子数据：演示三种方案的 ID 特征

-- 1. AUTO_INCREMENT 表：插入 5 行观察 ID 分布
INSERT INTO t_auto_inc (name, val) VALUES
    ('auto_inc_a', 100),
    ('auto_inc_b', 200),
    ('auto_inc_c', 300),
    ('auto_inc_d', 400),
    ('auto_inc_e', 500);

SELECT '--- t_auto_inc ---' AS info;
SELECT * FROM t_auto_inc ORDER BY id;

-- 2. AUTO_RANDOM 表：插入 5 行观察 ID 特征（打散高位，不连续）
INSERT INTO t_auto_rand (name, val) VALUES
    ('auto_rand_a', 100),
    ('auto_rand_b', 200),
    ('auto_rand_c', 300),
    ('auto_rand_d', 400),
    ('auto_rand_e', 500);

SELECT '--- t_auto_rand ---' AS info;
SELECT * FROM t_auto_rand ORDER BY id;

-- 3. Sequence 表：插入 5 行观察全局递增特征
INSERT INTO t_seq (name, val) VALUES
    ('seq_a', 100),
    ('seq_b', 200),
    ('seq_c', 300),
    ('seq_d', 400),
    ('seq_e', 500);

SELECT '--- t_seq ---' AS info;
SELECT * FROM t_seq ORDER BY id;

-- 检查三种方案 ID 的连续性
SELECT
    'AUTO_INCREMENT' AS scheme,
    COUNT(*) AS row_count,
    MIN(id) AS min_id,
    MAX(id) AS max_id,
    MAX(id) - MIN(id) + 1 AS consecutive_range,
    CASE WHEN MAX(id) - MIN(id) + 1 = COUNT(*) THEN 'YES' ELSE 'NO' END AS is_consecutive
FROM t_auto_inc

UNION ALL

SELECT
    'AUTO_RANDOM',
    COUNT(*),
    MIN(id),
    MAX(id),
    MAX(id) - MIN(id) + 1,
    CASE WHEN MAX(id) - MIN(id) + 1 = COUNT(*) THEN 'YES' ELSE 'NO' END
FROM t_auto_rand

UNION ALL

SELECT
    'Sequence',
    COUNT(*),
    MIN(id),
    MAX(id),
    MAX(id) - MIN(id) + 1,
    CASE WHEN MAX(id) - MIN(id) + 1 = COUNT(*) THEN 'YES' ELSE 'NO' END
FROM t_seq;
