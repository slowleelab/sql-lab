-- ============================================================
-- 造数据: 100 万用户数据
-- status 有 5 个值 (0-4)，city 有 100 个城市
-- ============================================================

DELIMITER $$
DROP PROCEDURE IF EXISTS sp_seed_user_merge $$
CREATE PROCEDURE sp_seed_user_merge()
BEGIN
    DECLARE i INT DEFAULT 0;
    DECLARE v_status TINYINT;
    DECLARE v_city VARCHAR(20);

    SET autocommit = 0;

    WHILE i < 1000000 DO
        SET v_status = FLOOR(RAND() * 5);
        SET v_city = CONCAT('city_', LPAD(FLOOR(1 + RAND() * 100), 3, '0'));

        INSERT INTO t_user_merge (username, phone, status, city, email, created_at)
        VALUES (
            CONCAT('user_', LPAD(i, 7, '0')),
            CONCAT('1', ELT(FLOOR(1 + RAND() * 7), '3','5','7','8','9','4','6'),
                   LPAD(FLOOR(RAND() * 100000000), 9, '0')),
            v_status,
            v_city,
            CONCAT('user_', LPAD(i, 7, '0'), '@example.com'),
            NOW() - INTERVAL FLOOR(RAND() * 730) DAY
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

CALL sp_seed_user_merge();
DROP PROCEDURE IF EXISTS sp_seed_user_merge;

-- 插入固定测试数据，确保 city='北京' 有数据
INSERT INTO t_user_merge (username, phone, status, city, email, created_at)
VALUES
    ('test_bj_01', '13800138001', 1, '北京', 'bj01@example.com', NOW()),
    ('test_bj_02', '13800138002', 2, '北京', 'bj02@example.com', NOW()),
    ('test_bj_03', '13800138003', 0, '北京', 'bj03@example.com', NOW());

-- 确认数据量
SELECT COUNT(*) AS total_rows FROM t_user_merge;
