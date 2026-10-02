-- ============================================================
-- 造数据: 20 万用户数据
-- ============================================================

DELIMITER $$
DROP PROCEDURE IF EXISTS sp_seed_user_search $$
CREATE PROCEDURE sp_seed_user_search()
BEGIN
    DECLARE i INT DEFAULT 0;
    SET autocommit = 0;

    WHILE i < 200000 DO
        INSERT INTO t_user_search (username, nickname, phone, created_at)
        VALUES (
            CONCAT('user_', LPAD(i, 6, '0')),                           -- user_000000
            CONCAT('nick', i),                                          -- 昵称
            CONCAT('1',
                   ELT(FLOOR(1 + RAND() * 7), '3','5','7','8','9','4','6'),
                   LPAD(FLOOR(RAND() * 100000000), 9, '0')),            -- 随机手机号
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

CALL sp_seed_user_search();
DROP PROCEDURE IF EXISTS sp_seed_user_search;

-- 插入一批以 zhang 开头的用户名，便于 bad/good 对比测试
INSERT INTO t_user_search (username, nickname, phone, created_at)
VALUES
    ('zhang_san',   '张三',   '13800138001', NOW()),
    ('zhang_si',    '张四',   '13800138002', NOW()),
    ('zhang_wu',    '张五',   '13800138003', NOW()),
    ('li_zhang',    '李张',   '13800138004', NOW()),
    ('wang_zhang',  '王张',   '13800138005', NOW());

-- 确认数据量
SELECT COUNT(*) AS total_rows FROM t_user_search;
