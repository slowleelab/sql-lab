-- ============================================================
-- 造数据: 30 万用户数据
-- ============================================================

DELIMITER $$
DROP PROCEDURE IF EXISTS sp_seed_user_or $$
CREATE PROCEDURE sp_seed_user_or()
BEGIN
    DECLARE i INT DEFAULT 0;
    DECLARE v_city VARCHAR(20);

    SET autocommit = 0;

    WHILE i < 300000 DO
        SET v_city = ELT(FLOOR(1 + RAND() * 8), '北京','上海','广州','深圳','杭州','成都','武汉','西安');

        INSERT INTO t_user_or (username, phone, status, city, created_at)
        VALUES (
            CONCAT('user_', LPAD(i, 6, '0')),                           -- user_000000
            CONCAT('1',
                   ELT(FLOOR(1 + RAND() * 7), '3','5','7','8','9','4','6'),
                   LPAD(FLOOR(RAND() * 100000000), 9, '0')),            -- 随机手机号
            IF(RAND() > 0.05, 1, 0),                                   -- 状态
            v_city,                                                     -- 城市
            NOW() - INTERVAL FLOOR(RAND() * 730) DAY                    -- 近2年随机时间
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

CALL sp_seed_user_or();
DROP PROCEDURE IF EXISTS sp_seed_user_or;

-- 插入固定手机号数据，便于 bad/good 对比测试
INSERT INTO t_user_or (username, phone, status, city, created_at)
VALUES
    ('test_user_01', '13800138000', 1, '北京', NOW()),
    ('test_user_02', '13800138000', 1, '上海', NOW());

-- 确认数据量
SELECT COUNT(*) AS total_rows FROM t_user_or;
