-- ============================================================
-- 案例十七: Hash Join vs BNL
-- 场景: 无索引 JOIN，对比 5.7 BNL 与 8.0 Hash Join，并演示加索引后更优
-- ============================================================

-- t_a: 5 万行
DROP TABLE IF EXISTS t_a;
CREATE TABLE t_a (
    id     BIGINT      NOT NULL AUTO_INCREMENT,
    val    INT         NOT NULL,
    name   VARCHAR(50) NOT NULL,
    PRIMARY KEY (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='表A';

-- t_b: 10 万行，a_id 故意不加索引
DROP TABLE IF EXISTS t_b;
CREATE TABLE t_b (
    id     BIGINT      NOT NULL AUTO_INCREMENT,
    a_id   INT         NOT NULL              COMMENT '关联A的ID',
    data   VARCHAR(50) NOT NULL,
    PRIMARY KEY (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='表B';
