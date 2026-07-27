-- bad.sql: 单行 INSERT 循环（每行一个事务）
--
-- 原理:
--   1. 每条 INSERT 是独立事务（autocommit=1 时自动提交）
--   2. 每次提交都要:
--      - 写 undo log（事务回滚日志）
--      - 写 redo log（WAL，fsync 刷盘）
--      - 更新 binlog（如开启）
--   3. 10 万次提交 = 10 万次 fsync，磁盘 I/O 是瓶颈
--   4. 每行单独解析 SQL、优化、执行，解析开销累积
--
--   生产中常见于 ORM 框架的默认 save() 行为:
--     for row in rows:
--         session.add(row)
--         session.commit()  # 每行提交！
--
--   以下演示单行 INSERT 语句（实际用程序循环执行 10 万次）

-- 单行插入示例（autocommit=1，每行自动提交一次事务）
INSERT INTO t_batch_data (user_name, email, amount, created_at)
VALUES ('user_000001', 'user_000001@example.com', 1234.56, NOW());

INSERT INTO t_batch_data (user_name, email, amount, created_at)
VALUES ('user_000002', 'user_000002@example.com', 2345.67, NOW());

INSERT INTO t_batch_data (user_name, email, amount, created_at)
VALUES ('user_000003', 'user_000003@example.com', 3456.78, NOW());

-- ... 重复 10 万次，每次一条 INSERT ...

-- 等效的存储过程模拟（注释展示，便于实测计时）:
-- DELIMITER $$
-- DROP PROCEDURE IF EXISTS sp_bad_insert $$
-- CREATE PROCEDURE sp_bad_insert()
-- BEGIN
--     DECLARE i INT DEFAULT 0;
--     SET autocommit = 1;  -- 每行自动提交
--     WHILE i < 100000 DO
--         INSERT INTO t_batch_data (user_name, email, amount, created_at)
--         VALUES (CONCAT('user_', LPAD(i, 6, '0')),
--                 CONCAT('user_', LPAD(i, 6, '0'), '@example.com'),
--                 ROUND(1 + RAND() * 9999, 2), NOW());
--         SET i = i + 1;
--     END WHILE;
-- END $$
-- DELIMITER ;
