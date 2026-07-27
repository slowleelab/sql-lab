-- TiDB CTE 与临时表优化
-- t_tree: 树形结构表，用于演示递归 CTE
-- t_cte_data: 数据表，用于演示非递归 CTE 物化

DROP TABLE IF EXISTS t_tree;
CREATE TABLE t_tree (
    id        BIGINT      NOT NULL AUTO_INCREMENT,
    parent_id BIGINT      DEFAULT NULL,
    name      VARCHAR(100) NOT NULL,
    PRIMARY KEY (id),
    KEY idx_parent (parent_id)
);

DROP TABLE IF EXISTS t_cte_data;
CREATE TABLE t_cte_data (
    id  BIGINT NOT NULL AUTO_INCREMENT,
    val INT    NOT NULL,
    PRIMARY KEY (id)
);
