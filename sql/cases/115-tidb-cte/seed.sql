-- seed.sql: 填充测试数据
-- t_tree: 500 行树形结构（10 层，每层约 50 个节点）
-- t_cte_data: 10 万行

DELIMITER $$
DROP PROCEDURE IF EXISTS sp_seed_tree $$
CREATE PROCEDURE sp_seed_tree()
BEGIN
    DECLARE level INT DEFAULT 0;
    DECLARE parent_start BIGINT;
    DECLARE parent_end BIGINT;
    DECLARE i INT;
    DECLARE pid BIGINT;
    DECLARE node_count INT DEFAULT 0;

    SET autocommit = 0;

    -- 插入根节点（第 0 层）
    INSERT INTO t_tree (parent_id, name) VALUES (NULL, 'Root');
    SET node_count = 1;

    -- 逐层插入：每层约 50 个节点
    SET level = 1;
    WHILE level <= 10 DO
        -- 上一层的节点范围
        SET parent_start = node_count - (SELECT COUNT(*) FROM t_tree WHERE id <= node_count AND parent_id IS NOT NULL);
        -- 简化：用上一层的全部节点作为父节点池
        SET parent_end = node_count;

        SET i = 0;
        WHILE i < 50 DO
            -- 随机选择上一层的某个节点作为父节点
            SET pid = parent_start + FLOOR(RAND() * (parent_end - parent_start + 1));
            INSERT INTO t_tree (parent_id, name) VALUES (pid, CONCAT('Node_L', level, '_N', i));
            SET node_count = node_count + 1;
            SET i = i + 1;
        END WHILE;

        SET level = level + 1;
        IF node_count % 500 = 0 THEN COMMIT; END IF;
    END WHILE;

    COMMIT;
    SET autocommit = 1;
END $$
DELIMITER ;

CALL sp_seed_tree();
DROP PROCEDURE IF EXISTS sp_seed_tree;
SELECT COUNT(*) AS tree_rows FROM t_tree;


-- 填充 t_cte_data：10 万行，val 范围 1~10000
DELIMITER $$
DROP PROCEDURE IF EXISTS sp_seed_cte_data $$
CREATE PROCEDURE sp_seed_cte_data()
BEGIN
    DECLARE i INT DEFAULT 0;
    SET autocommit = 0;
    WHILE i < 100000 DO
        INSERT INTO t_cte_data (val) VALUES (FLOOR(1 + RAND() * 10000));
        SET i = i + 1;
        IF i % 5000 = 0 THEN COMMIT; END IF;
    END WHILE;
    COMMIT;
    SET autocommit = 1;
END $$
DELIMITER ;

CALL sp_seed_cte_data();
DROP PROCEDURE IF EXISTS sp_seed_cte_data;
SELECT COUNT(*) AS cte_data_rows FROM t_cte_data;
