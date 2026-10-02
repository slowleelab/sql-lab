-- ============================================================
-- 造数据: 20 万用户数据
-- ============================================================

DELIMITER $$
DROP PROCEDURE IF EXISTS sp_seed_icp $$
CREATE PROCEDURE sp_seed_icp()
BEGIN
    DECLARE i INT DEFAULT 0;
    DECLARE v_prefix VARCHAR(4);
    DECLARE v_name VARCHAR(50);
    SET autocommit = 0;

    WHILE i < 200000 DO
        -- 只用少数几个前缀，让每个前缀匹配很多行（方便展示 ICP 的效果）
        SET v_prefix = ELT(FLOOR(1 + RAND() * 5), '1380','1390','1360','1350','1580');
        SET v_name = CONCAT(ELT(FLOOR(1 + RAND() * 5), '张','王','李','赵','刘'),
                           ELT(FLOOR(1 + RAND() * 5), '伟','芳','娜','秀英','敏'),
                           ELT(FLOOR(1 + RAND() * 5), '','明','强','磊','洋'));

        INSERT INTO t_user_icp (phone_prefix, name, phone, city, created_at)
        VALUES (
            v_prefix,
            v_name,
            CONCAT(v_prefix, LPAD(FLOOR(RAND() * 10000000), 7, '0')),
            ELT(FLOOR(1 + RAND() * 5), '北京','上海','广州','深圳','杭州'),
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

CALL sp_seed_icp();
DROP PROCEDURE IF EXISTS sp_seed_icp;

SELECT COUNT(*) AS total_rows FROM t_user_icp;
