-- ============================================================
-- 造数据: 10 万行订单数据，bad 表与 good 表业务数据一一对应
-- 关键设计:
--   1. status 在 5 种状态间分布（bad 存中文，good 存整数编码）
--   2. gender 在 男/女/未知 间分布（bad 存中文，good 存 M/F/U）
--   3. remark 只有一半行有值（展示 VARCHAR 空值不占行内空间）
--   4. amount 用 99.90 等典型值（bad 存 FLOAT 会产生精度偏差）
-- ============================================================

DELIMITER $$
DROP PROCEDURE IF EXISTS sp_seed_type_compare $$
CREATE PROCEDURE sp_seed_type_compare()
BEGIN
    DECLARE i INT DEFAULT 0;
    DECLARE v_status_bad VARCHAR(20);
    DECLARE v_status_good TINYINT UNSIGNED;
    DECLARE v_gender_bad VARCHAR(10);
    DECLARE v_gender_good CHAR(1);
    DECLARE v_phone VARCHAR(20);
    DECLARE v_amount DECIMAL(10,2);
    DECLARE v_remark_bad VARCHAR(1000);
    DECLARE v_remark_good VARCHAR(500);
    DECLARE v_isdel_bad VARCHAR(5);
    DECLARE v_isdel_good TINYINT(1);
    DECLARE v_rnd INT;
    SET autocommit = 0;

    WHILE i < 100000 DO
        SET v_rnd = FLOOR(RAND() * 5);
        -- status: 5 种状态，bad 存中文 / good 存整数
        CASE v_rnd
            WHEN 0 THEN SET v_status_bad = '待支付'; SET v_status_good = 0;
            WHEN 1 THEN SET v_status_bad = '已支付'; SET v_status_good = 1;
            WHEN 2 THEN SET v_status_bad = '已发货'; SET v_status_good = 2;
            WHEN 3 THEN SET v_status_bad = '已完成'; SET v_status_good = 3;
            ELSE      SET v_status_bad = '已取消'; SET v_status_good = 4;
        END CASE;

        -- gender: 男/女/未知，bad 存中文 / good 存单字符
        SET v_rnd = FLOOR(RAND() * 3);
        CASE v_rnd
            WHEN 0 THEN SET v_gender_bad = '男'; SET v_gender_good = 'M';
            WHEN 1 THEN SET v_gender_bad = '女'; SET v_gender_good = 'F';
            ELSE      SET v_gender_bad = '未知'; SET v_gender_good = 'U';
        END CASE;

        -- 手机号: 11 位，以 1 开头
        SET v_phone = CONCAT('1', FLOOR(3 + RAND() * 5), LPAD(FLOOR(RAND() * 1000000000), 9, '0'));

        -- 金额: 在 9.90 ~ 999.90 之间，部分行恰好为 99.90（演示 FLOAT 精度问题）
        IF i % 1000 = 0 THEN
            SET v_amount = 99.90;
        ELSE
            SET v_amount = ROUND(9.90 + RAND() * 990.00, 2);
        END IF;

        -- remark: 只有一半行有值（展示 VARCHAR 空值不占行内空间）
        IF i % 2 = 0 THEN
            SET v_remark_bad  = CONCAT('订单备注内容编号', LPAD(i, 6, '0'), '，用于演示VARCHAR存储差异');
            SET v_remark_good = CONCAT('订单备注内容编号', LPAD(i, 6, '0'), '，用于演示VARCHAR存储差异');
        ELSE
            SET v_remark_bad  = NULL;
            SET v_remark_good = NULL;
        END IF;

        -- is_deleted: 5% 已删除，bad 存字符串 / good 存 TINYINT
        IF RAND() < 0.05 THEN
            SET v_isdel_bad = 'true';
            SET v_isdel_good = 1;
        ELSE
            SET v_isdel_bad = 'false';
            SET v_isdel_good = 0;
        END IF;

        INSERT INTO t_type_bad (order_no, user_id, status, gender, phone, amount, remark, is_deleted, created_at)
        VALUES (
            CONCAT('ORD', LPAD(i, 8, '0')),
            1 + FLOOR(RAND() * 10000),
            v_status_bad, v_gender_bad, v_phone,
            v_amount, v_remark_bad, v_isdel_bad,
            NOW() - INTERVAL FLOOR(RAND() * 365) DAY
        );

        INSERT INTO t_type_good (order_no, user_id, status, gender, phone, amount, remark, is_deleted, created_at)
        VALUES (
            CONCAT('ORD', LPAD(i, 8, '0')),
            1 + FLOOR(RAND() * 10000),
            v_status_good, v_gender_good, v_phone,
            v_amount, v_remark_good, v_isdel_good,
            NOW() - INTERVAL FLOOR(RAND() * 365) DAY
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

CALL sp_seed_type_compare();
DROP PROCEDURE IF EXISTS sp_seed_type_compare;

-- 确认数据量一致
SELECT 't_type_bad'  AS tbl, COUNT(*) AS total_rows FROM t_type_bad
UNION ALL
SELECT 't_type_good', COUNT(*) FROM t_type_good;

-- 验证 amount=99.90 的行数（bad 表因 FLOAT 精度可能查不全）
SELECT 't_type_bad amount=99.90'  AS check_item, COUNT(*) AS cnt
FROM t_type_bad  WHERE amount = 99.90
UNION ALL
SELECT 't_type_good amount=99.90', COUNT(*)
FROM t_type_good WHERE amount = 99.90;
