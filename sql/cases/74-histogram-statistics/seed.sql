-- ============================================================
-- 造数据: 20 万任务，status 分布极度不均（99% 为 0，0.5% 为 1，0.5% 为 2）
-- user_id 在 1~2000 范围内，每个 user_id 约 100 条任务
-- ============================================================

DELIMITER $$
DROP PROCEDURE IF EXISTS sp_seed_task $$
CREATE PROCEDURE sp_seed_task()
BEGIN
    DECLARE i INT DEFAULT 0;
    DECLARE v_status TINYINT;
    SET autocommit = 0;

    WHILE i < 200000 DO
        -- 99% 的数据 status=0，制造严重的数据倾斜
        IF RAND() < 0.99 THEN
            SET v_status = 0;
        ELSE
            SET v_status = ELT(FLOOR(1 + RAND() * 2), 1, 2);
        END IF;

        INSERT INTO t_task (user_id, status, created_at)
        VALUES (
            FLOOR(1 + RAND() * 2000),
            v_status,
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

CALL sp_seed_task();
DROP PROCEDURE IF EXISTS sp_seed_task;

-- 展示 status 分布倾斜情况
SELECT status, COUNT(*) AS cnt, ROUND(COUNT(*)*100/200000, 2) AS pct FROM t_task GROUP BY status ORDER BY status;

SELECT COUNT(*) AS total_rows FROM t_task;
