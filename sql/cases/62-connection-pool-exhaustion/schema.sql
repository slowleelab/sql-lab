-- ============================================================
-- 案例七十五: 连接池与 max_connections 耗尽诊断
-- 场景: 慢 SQL 占用连接导致 "Too many connections"
--        故意只建主键索引，让 user_id/data_value 查询走全表扫描
-- ============================================================

-- 连接测试表: 10 万行
-- 故意只保留主键索引，user_id / data_value 无索引
-- 这样按 user_id / data_value 过滤会全表扫描，模拟"慢 SQL 占连接"
DROP TABLE IF EXISTS t_conn_test;
CREATE TABLE t_conn_test (
    id          BIGINT       NOT NULL AUTO_INCREMENT,
    user_id     BIGINT       NOT NULL                COMMENT '用户ID（无索引，查询会全表扫描）',
    data_value  VARCHAR(200) NOT NULL DEFAULT ''     COMMENT '数据值（无索引）',
    created_at  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
    PRIMARY KEY (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='连接池诊断测试表';
