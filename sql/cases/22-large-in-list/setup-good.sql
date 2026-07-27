-- setup-good.sql: 准备临时表并填充目标 user_id 列表
-- 将大 IN 列表转为临时表，后续走标准 JOIN 路径
DROP TABLE IF EXISTS tmp_target_users;
CREATE TABLE tmp_target_users (
    user_id BIGINT NOT NULL,
    PRIMARY KEY (user_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='目标用户临时表';

-- 填入 1000 个目标 user_id（与 bad.sql 中的子查询逻辑等价）
INSERT INTO tmp_target_users (user_id)
SELECT DISTINCT user_id FROM t_order_in LIMIT 1000;
