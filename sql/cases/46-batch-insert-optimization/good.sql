-- good.sql: 批量 INSERT + 事务批量提交
--
-- 原理:
--   1. 多行 VALUES 合并为一条 INSERT，减少 SQL 解析次数
--      INSERT INTO ... VALUES (...),(...),(...)  -- 一条语句插多行
--   2. 关闭 autocommit，手动控制事务，批量提交
--      每 5000 行 COMMIT 一次，而非每行提交
--   3. 10 万行 / 5000 = 20 次提交（vs bad 的 10 万次提交）
--   4. 减少 fsync 次数、redo log 写入、binlog event 数量
--
--   生产中 ORM 框架的批量插入模式:
--     session.add_all(rows)
--     session.commit()  # 一次性提交
--
--   以下演示批量 INSERT 语句（实际用程序或存储过程循环）

-- 多行批量 INSERT 示例（一条语句插入多行）
INSERT INTO t_batch_data (user_name, email, amount, created_at)
VALUES
    ('user_100001', 'user_100001@example.com', 1234.56, NOW()),
    ('user_100002', 'user_100002@example.com', 2345.67, NOW()),
    ('user_100003', 'user_100003@example.com', 3456.78, NOW()),
    ('user_100004', 'user_100004@example.com', 4567.89, NOW()),
    ('user_100005', 'user_100005@example.com', 5678.90, NOW());
-- ... 每批 5000 行，共 20 批 ...

-- 批量插入的存储过程实现（关闭 autocommit，每 5000 行提交一次）:
DELIMITER $$
DROP PROCEDURE IF EXISTS sp_good_insert $$
CREATE PROCEDURE sp_good_insert()
BEGIN
    DECLARE i INT DEFAULT 0;
    SET autocommit = 0;  -- 关闭自动提交

    WHILE i < 100000 DO
        INSERT INTO t_batch_data (user_name, email, amount, created_at)
        VALUES (
            CONCAT('user_', LPAD(i, 6, '0')),
            CONCAT('user_', LPAD(i, 6, '0'), '@example.com'),
            ROUND(1 + RAND() * 9999, 2),
            NOW()
        );
        SET i = i + 1;

        IF i % 5000 = 0 THEN
            COMMIT;  -- 每 5000 行提交一次
        END IF;
    END WHILE;

    COMMIT;
    SET autocommit = 1;
END $$
DELIMITER ;

-- 执行批量插入（取消注释以实测）
-- CALL sp_good_insert();
-- DROP PROCEDURE IF EXISTS sp_good_insert;

-- ============================================================
-- 进阶优化: LOAD DATA INFILE（最快的大批量导入方式）
-- ============================================================
-- 适用于从 CSV 文件导入超大数据集（百万~亿级）
--
-- 1. 准备 CSV 文件 data.csv:
--    user_000001,user_000001@example.com,1234.56,2024-01-01 12:00:00
--    user_000002,user_000002@example.com,2345.67,2024-01-01 12:00:00
--    ...
--
-- 2. 执行导入（关闭 autocommit，或用 SET autocommit=0 + 手动 COMMIT）:
-- SET autocommit = 0;
-- LOAD DATA INFILE '/path/to/data.csv'
-- INTO TABLE t_batch_data
-- FIELDS TERMINATED BY ','
-- LINES TERMINATED BY '\n'
-- (user_name, email, amount, created_at);
-- COMMIT;
--
-- LOAD DATA 比逐行 INSERT 快 20-100 倍，因为:
--   - 单次事务，一次提交
--   - 批量解析，无逐条 SQL 解析开销
--   - 顺序写入，最小化索引维护开销
