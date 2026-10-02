-- ============================================================
-- 造数据: 组织架构树，1个CEO下多层管理者，共约 12 万员工
-- 结构: 1个CEO(level1) -> 5个VP(level2) -> 每VP 10个总监(level3)
--       -> 每总监 20个经理(level4) -> 每经理 100个员工(level5)
--   1 + 5 + 50 + 1000 + 100000 = 101056 人
-- ============================================================

DELIMITER $$
DROP PROCEDURE IF EXISTS sp_seed_org $$
CREATE PROCEDURE sp_seed_org()
BEGIN
    DECLARE v_ceo_id BIGINT;
    DECLARE v_vp INT;
    DECLARE v_dir INT;
    DECLARE v_mgr INT;
    DECLARE v_emp INT;
    DECLARE v_vp_id BIGINT;
    DECLARE v_dir_id BIGINT;
    DECLARE v_mgr_id BIGINT;
    DECLARE v_inserted INT DEFAULT 0;
    SET autocommit = 0;

    -- CEO (level 1)
    INSERT INTO t_employee_org (emp_name, manager_id, level)
    VALUES ('CEO张总', NULL, 1);
    SET v_ceo_id = LAST_INSERT_ID();
    COMMIT;

    -- 5 个 VP (level 2)
    SET v_vp = 0;
    WHILE v_vp < 5 DO
        INSERT INTO t_employee_org (emp_name, manager_id, level)
        VALUES (CONCAT('VP-', v_vp+1), v_ceo_id, 2);
        SET v_vp_id = LAST_INSERT_ID();

        -- 每个 VP 下 10 个总监 (level 3)
        SET v_dir = 0;
        WHILE v_dir < 10 DO
            INSERT INTO t_employee_org (emp_name, manager_id, level)
            VALUES (CONCAT('总监-', v_vp+1, '-', v_dir+1), v_vp_id, 3);
            SET v_dir_id = LAST_INSERT_ID();

            -- 每个总监下 20 个经理 (level 4)
            SET v_mgr = 0;
            WHILE v_mgr < 20 DO
                INSERT INTO t_employee_org (emp_name, manager_id, level)
                VALUES (CONCAT('经理-', v_vp+1, '-', v_dir+1, '-', v_mgr+1), v_dir_id, 4);
                SET v_mgr_id = LAST_INSERT_ID();

                -- 每个经理下 100 个员工 (level 5)
                SET v_emp = 0;
                WHILE v_emp < 100 DO
                    INSERT INTO t_employee_org (emp_name, manager_id, level)
                    VALUES (CONCAT('员工-', v_mgr_id, '-', v_emp+1), v_mgr_id, 5);
                    SET v_emp = v_emp + 1;
                    SET v_inserted = v_inserted + 1;

                    IF v_inserted % 5000 = 0 THEN
                        COMMIT;
                    END IF;
                END WHILE;

                SET v_mgr = v_mgr + 1;
            END WHILE;

            SET v_dir = v_dir + 1;
        END WHILE;

        SET v_vp = v_vp + 1;
    END WHILE;

    COMMIT;
    SET autocommit = 1;
END $$
DELIMITER ;

CALL sp_seed_org();
DROP PROCEDURE IF EXISTS sp_seed_org;

-- 查看各层级人数
SELECT level, COUNT(*) AS cnt FROM t_employee_org GROUP BY level ORDER BY level;

SELECT COUNT(*) AS total_rows FROM t_employee_org;
